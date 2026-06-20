//
//  SSHService.swift
//  Argos
//
//  Actor que encapsula la conexión SSH (Citadel) y la consulta de sesiones tmux.
//
//  API REAL de Citadel utilizada (leída del código fuente del paquete):
//   - Carga de clave Ed25519 OpenSSH:
//        Curve25519.Signing.PrivateKey(sshEd25519: String, decryptionKey: Data? = nil)
//        (extensión pública definida en Citadel/SSHCert.swift; la passphrase va en
//         `decryptionKey` como Data UTF-8, o `nil` si la clave no tiene passphrase).
//   - Método de autenticación por clave:
//        SSHAuthenticationMethod.ed25519(username:privateKey:)
//   - Conexión:
//        SSHClient.connect(host:port:authenticationMethod:hostKeyValidator:reconnect:)
//   - Ejecución de comando:
//        SSHClient.executeCommandStream(_:)  ->  AsyncThrowingStream<ExecCommandOutput, Error>
//

import Foundation
import os
import Citadel
import Crypto      // Curve25519.Signing.PrivateKey
import NIOCore     // ByteBuffer, String(buffer:)

/// Gestiona una conexión SSH a un host y lista sus sesiones tmux.
///
/// Es un `actor`: el `SSHClient` (no `Sendable`) queda protegido por el
/// aislamiento del actor, evitando accesos concurrentes a la conexión.
actor SSHService {

    // MARK: - Configuración

    /// Parámetros de conexión a un servidor, derivados de un `Server` persistido.
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var username: String
        /// Ruta a la clave privada (admite `~`). Modo sin sandbox / informativa.
        var privateKeyPath: String
        /// Security-scoped bookmark a la clave (modo App Sandbox). Si está presente,
        /// tiene prioridad sobre `privateKeyPath` al leer la clave.
        var privateKeyBookmark: Data?
        /// Passphrase de la clave. La provee el llamador (desde Keychain), NUNCA
        /// se hardcodea. `nil` = clave sin passphrase. Se convierte a Data efímera.
        var passphrase: String?
        /// Método de autenticación (clave o contraseña).
        var authMethod: AuthMethod
        /// Contraseña de login (solo para `authMethod == .password`), desde Keychain.
        var password: String?

        /// Construye la configuración de transporte a partir de un `Server` y el secreto
        /// recuperado de Keychain: passphrase (auth por clave) o contraseña (auth por
        /// contraseña), según `server.authMethod`.
        init(server: Server, passphrase: String? = nil, password: String? = nil) {
            self.host = server.host
            self.port = server.port
            self.username = server.username
            self.privateKeyPath = server.privateKeyPath
            self.privateKeyBookmark = server.privateKeyBookmark
            self.authMethod = server.authMethod
            self.passphrase = passphrase
            self.password = password
        }
    }

    // MARK: - Errores

    enum SSHServiceError: LocalizedError {
        case keyUnreadable(path: String, underlying: Error)
        case keyParseFailed(underlying: Error)
        case commandFailed(exitCode: Int, message: String)
        case tmuxNotInstalled
        case installFailed(String)
        case configFailed(String)
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .keyUnreadable(let path, _):
                return "No se pudo leer la clave privada en \(path)."
            case .keyParseFailed:
                return "No se pudo cargar la clave Ed25519. Verifica que esté en formato OpenSSH "
                     + "y, si tiene passphrase, que se haya inyectado correctamente."
            case .commandFailed(let exitCode, let message):
                return "El comando remoto falló (código \(exitCode)): \(message)"
            case .tmuxNotInstalled:
                return "tmux no está instalado en el servidor."
            case .installFailed(let message):
                return "No se pudo instalar tmux. \(message)"
            case .configFailed(let message):
                return "No se pudo crear ~/.tmux.conf. \(message)"
            case .uploadFailed(let message):
                return "No se pudo subir el archivo al servidor. \(message)"
            }
        }
    }

    /// Mensaje accionable cuando tmux falta y no hay sudo sin contraseña: lo resuelve
    /// el usuario fuera de la app (la app NUNCA pide ni guarda la contraseña de sudo).
    static let manualInstallInstruction =
        "tmux no está instalado y tu usuario no tiene sudo sin contraseña. "
        + "Instálalo con: sudo apt install tmux"

    // MARK: - Estado

    private let configuration: Configuration
    private var client: SSHClient?

    /// Tarea de heartbeat de la conexión actual (keep-alive). Ver `startHeartbeat`.
    private var heartbeatTask: Task<Void, Never>?

    /// Intervalo del heartbeat: más corto que los timeouts típicos de NAT/firewall
    /// (~60-120s) para que la conexión idle no se corte sin que la app lo sepa.
    private static let heartbeatInterval: Duration = .seconds(30)

    /// Formato exacto requerido para `tmux list-sessions -F`.
    private static let sessionFormat =
        "#{session_name}|#{session_windows}|#{session_attached}|#{session_created}"

    private static var listSessionsCommand: String {
        "tmux list-sessions -F '\(sessionFormat)'"
    }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - API pública

    /// Conecta (si hace falta) y devuelve las sesiones tmux del servidor.
    ///
    /// "no server running" o "no sessions" se tratan como **lista vacía**, no como error.
    func listSessions() async throws -> [TmuxSession] {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.listSessionsCommand)

        if result.exitCode != 0 {
            // 1) tmux instalado pero sin servidor / sin sesiones -> [] (caso normal).
            if Self.indicatesNoTmuxServer(stdout: result.stdout, stderr: result.stderr) {
                return []
            }
            // 2) tmux no instalado (exit 127 / "command not found") -> error específico
            //    para que la UI ofrezca instalarlo.
            if Self.indicatesTmuxNotInstalled(
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode
            ) {
                throw SSHServiceError.tmuxNotInstalled
            }
            // 3) cualquier otro fallo real se propaga.
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? "tmux list-sessions no devolvió detalles." : message
            )
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { TmuxSession(line: String($0)) }
    }

    /// Cierra la conexión SSH si está abierta.
    func disconnect() async {
        stopHeartbeat()
        guard let client else { return }
        try? await client.close()
        self.client = nil
    }

    /// Prueba la conexión con la configuración actual: conecta (verificando host key,
    /// autenticando) y ejecuta `whoami`, devolviendo el usuario remoto. Lanza si la
    /// conexión o la autenticación fallan. Pensado para el botón "Probar conexión": el
    /// llamador debe hacer `disconnect()` después. El `SSHClient` (no-Sendable) no sale
    /// del actor.
    func testConnection() async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: "whoami")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reconoce los mensajes con los que tmux indica "no hay servidor / sesiones".
    ///
    /// El texto varía según versión/plataforma de tmux. Todos estos casos significan
    /// simplemente que no hay sesiones que listar y deben tratarse como lista vacía:
    ///  - `no server running on /tmp/tmux-1000/default`
    ///  - `error connecting to /tmp/tmux-1000/default (No such file or directory)`
    ///    (el socket no existe porque el servidor nunca arrancó)
    ///  - `failed to connect to server`
    ///  - `no sessions`
    ///
    /// Errores reales (p. ej. `tmux: command not found`, exit 127) NO coinciden con
    /// estos marcadores y se propagan como `SSHServiceError.commandFailed`.
    static func indicatesNoTmuxServer(stdout: String, stderr: String) -> Bool {
        let haystack = (stdout + "\n" + stderr).lowercased()
        let noServerMarkers = [
            "no server running",
            "error connecting to",
            "failed to connect to server",
            "no sessions"
        ]
        return noServerMarkers.contains { haystack.contains($0) }
    }

    /// Detecta que el binario `tmux` no existe en el servidor.
    ///
    /// El shell remoto devuelve código 127 y un mensaje del tipo
    /// `bash: tmux: command not found` / `sh: tmux: not found` cuando el comando
    /// no se encuentra. Se comprueba DESPUÉS de `indicatesNoTmuxServer` para no
    /// confundir "no hay servidor" con "no está instalado".
    static func indicatesTmuxNotInstalled(
        stdout: String,
        stderr: String,
        exitCode: Int
    ) -> Bool {
        let haystack = (stdout + "\n" + stderr).lowercased()
        if haystack.contains("command not found") || haystack.contains("tmux: not found") {
            return true
        }
        // 127 = "command not found" del shell. Confirmamos que se refiere a tmux.
        return exitCode == 127 && haystack.contains("tmux")
    }

    // MARK: - Preparación del entorno tmux (detección / instalación / configuración)
    //
    // Pensado para Ubuntu/Debian (apt). El orquestador (la UI) llama a estos pasos en
    // secuencia y refleja cada fase. Todos son idempotentes y no interactivos: nunca se
    // queda colgado pidiendo contraseña (se usa `sudo -n`) ni se pide/guarda la contraseña.

    /// Detecta si tmux está instalado en el servidor (`command -v tmux`).
    func isTmuxInstalled() async throws -> Bool {
        let client = try await connectedClient()
        let result = try await capture(client, command: "command -v tmux")
        return result.exitCode == 0
    }

    /// ¿Puede el usuario ejecutar sudo SIN contraseña? (`sudo -n true`).
    ///
    /// `sudo -n` falla en vez de pedir contraseña, así que es seguro de probar en un
    /// canal sin TTY: nunca bloquea.
    func canUseSudoNonInteractive() async throws -> Bool {
        let client = try await connectedClient()
        let result = try await capture(client, command: "sudo -n true")
        return result.exitCode == 0
    }

    /// Instala tmux con apt y verifica al final con `command -v tmux`.
    ///
    /// Precondición: el llamador ya comprobó `canUseSudoNonInteractive()`. Se ejecuta
    /// todo dentro de un único `sudo -n sh -c …` como root, con
    /// `DEBIAN_FRONTEND=noninteractive` para que apt no abra diálogos.
    /// Lanza `SSHServiceError.installFailed` si tras instalar tmux sigue sin aparecer.
    func installTmuxWithApt() async throws {
        let client = try await connectedClient()
        let install =
            "sudo -n sh -c 'apt-get update && "
            + "DEBIAN_FRONTEND=noninteractive apt-get install -y tmux'"
        let result = try await capture(client, command: install)

        // Verificación independiente del código de salida de apt.
        let check = try await capture(client, command: "command -v tmux")
        guard check.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.installFailed(
                detail.isEmpty ? "apt terminó con código \(result.exitCode)." : detail
            )
        }
    }

    // MARK: - Configuración de ~/.tmux.conf

    /// Contenido base de `~/.tmux.conf` (mouse, scrollback, índices base 1, colores).
    ///
    /// `default-terminal "tmux-256color"` + el override `Tc` habilitan truecolor; si
    /// SwiftTerm anuncia otro `TERM` y hay problemas de color, este es el primer ajuste
    /// a revisar.
    private static let defaultTmuxConfig = [
        "set -g mouse on",
        "set -g history-limit 50000",
        "set -g base-index 1",
        "setw -g pane-base-index 1",
        "set -g renumber-windows on",
        "set -sg escape-time 0",
        "set -g default-terminal \"tmux-256color\"",
        "set -ga terminal-overrides \",*256col*:Tc\"",
        // Portapapeles: reenvía las secuencias OSC 52 que emiten las apps (p. ej. la
        // opción "c to copy" de Claude Code) al terminal exterior (SwiftTerm), que las
        // copia al portapapeles del Mac. El override `Ms` declara que el terminal soporta
        // OSC 52 aunque su terminfo no lo anuncie.
        "set -g set-clipboard on",
        "set -ga terminal-overrides \",*:Ms=\\\\E]52;%p1%s;%p2%s\\\\007\"",
    ].joined(separator: "\n")

    /// ¿Existe ya `~/.tmux.conf`? (`test -f "$HOME/.tmux.conf"`).
    func tmuxConfigExists() async throws -> Bool {
        let client = try await connectedClient()
        let result = try await capture(client, command: "test -f \"$HOME/.tmux.conf\"")
        return result.exitCode == 0
    }

    /// Crea `~/.tmux.conf` con la base por defecto **solo si no existe** (no sobreescribe).
    ///
    /// El `if [ ! -f ]` interno hace la operación idempotente y a prueba de carreras; el
    /// heredoc con delimitador entrecomillado escribe el contenido literal sin expansión.
    func writeDefaultTmuxConfig() async throws {
        let client = try await connectedClient()
        let command =
            "if [ ! -f \"$HOME/.tmux.conf\" ]; then\n"
            + "cat > \"$HOME/.tmux.conf\" <<'ARGOS_TMUX_CONF'\n"
            + Self.defaultTmuxConfig + "\n"
            + "ARGOS_TMUX_CONF\n"
            + "fi"
        let result = try await capture(client, command: command)
        if result.exitCode != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.configFailed(
                detail.isEmpty ? "Código de salida \(result.exitCode)." : detail
            )
        }
    }

    /// Habilita el reenvío de OSC 52 en el servidor tmux **en ejecución**, para que
    /// servidores ya configurados (sin `set-clipboard on` en su `~/.tmux.conf`) también
    /// puedan copiar al portapapeles del Mac. Best-effort: si no hay servidor tmux o el
    /// comando falla, se ignora silenciosamente (no debe bloquear la conexión).
    func enableClipboardForwarding() async {
        guard let client = try? await connectedClient() else { return }
        let command =
            "tmux set -g set-clipboard on 2>/dev/null; "
            + "tmux set -ga terminal-overrides ',*:Ms=\\E]52;%p1%s;%p2%s\\007' 2>/dev/null; true"
        _ = try? await capture(client, command: command)
    }

    // MARK: - Conexión

    /// Conexión SSH compartida. `internal` (no `private`) para que la extensión del
    /// terminal en vivo (`SSHTerminalSession.swift`) reutilice el mismo `SSHClient`.
    func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected {
            return client
        }

        let authentication = try makeAuthenticationMethod()

        // Verificación de host key con Trust-On-First-Use (estilo known_hosts).
        // NO usamos `.acceptAnything()`: dejaría la conexión expuesta a MitM, algo
        // crítico ahora que la app puede ejecutar comandos privilegiados (instalar tmux).
        let hostKeyValidator = TOFUHostKeyValidator(
            host: configuration.host,
            port: configuration.port
        )

        let client = try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: authentication,
            hostKeyValidator: .custom(hostKeyValidator),
            reconnect: .never
        )

        self.client = client
        Log.ssh.notice("Conexión SSH establecida con \(self.configuration.host, privacy: .public):\(self.configuration.port)")
        startHeartbeat()
        return client
    }

    // MARK: - Heartbeat (keep-alive)

    /// Arranca el heartbeat de la conexión actual. Ejecuta un comando trivial cada
    /// `heartbeatInterval` para: (a) evitar que NAT/firewall corten la conexión idle —la
    /// causa del "terminal congelado" al volver tras un rato—, y (b) detectar pronto una
    /// caída en vez de descubrirla al próximo uso (cuando el indicador seguiría "verde").
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SSHService.heartbeatInterval)
                guard let self else { return }
                let alive = await self.beat()
                if !alive { return }
            }
        }
    }

    /// Un latido: comprueba la conexión con un comando trivial. Devuelve `false` si la
    /// conexión está caída y la limpia, forzando una reconexión en la próxima operación.
    private func beat() async -> Bool {
        guard let client, client.isConnected else { return false }
        do {
            _ = try await capture(client, command: "true")
            return true
        } catch {
            Log.ssh.notice("Heartbeat falló en \(self.configuration.host, privacy: .public); se marca la conexión como caída.")
            self.client = nil
            return false
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Construye el método de autenticación según el `authMethod` configurado:
    /// clave Ed25519 (con passphrase opcional) o usuario+contraseña.
    private func makeAuthenticationMethod() throws -> SSHAuthenticationMethod {
        switch configuration.authMethod {
        case .key:
            let privateKey = try loadPrivateKey()
            return .ed25519(username: configuration.username, privateKey: privateKey)
        case .password:
            return .passwordBased(
                username: configuration.username,
                password: configuration.password ?? ""
            )
        }
    }

    /// Lee y parsea la clave Ed25519 OpenSSH del disco.
    private func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        let keyText = try readKeyText()

        // Passphrase opcional -> Data UTF-8 (nil si la clave no está cifrada).
        let decryptionKey = configuration.passphrase.map { Data($0.utf8) }

        do {
            return try Curve25519.Signing.PrivateKey(
                sshEd25519: keyText,
                decryptionKey: decryptionKey
            )
        } catch {
            throw SSHServiceError.keyParseFailed(underlying: error)
        }
    }

    /// Lee el texto de la clave privada. Bajo App Sandbox resuelve el
    /// security-scoped bookmark que el usuario concedió al elegir el archivo; si
    /// no hay bookmark (modo sin sandbox), lee por ruta directa (admite `~`).
    private func readKeyText() throws -> String {
        if let bookmark = configuration.privateKeyBookmark {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw SSHServiceError.keyUnreadable(
                    path: configuration.privateKeyPath, underlying: error
                )
            }
        }

        let path = Self.expandKeyPath(configuration.privateKeyPath)
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SSHServiceError.keyUnreadable(path: path, underlying: error)
        }
    }

    // MARK: - Utilidades de ruta

    /// Expande `~` al home real del usuario (no al container de sandbox).
    /// Bajo App Sandbox `NSHomeDirectory()` devuelve el home del container;
    /// `getpwuid` devuelve siempre el home POSIX real.
    private static func expandKeyPath(_ path: String) -> String {
        guard path.hasPrefix("~/") || path == "~" else { return path }
        var realHome = NSHomeDirectory()
        if let pw = getpwuid(getuid()) {
            realHome = String(cString: pw.pointee.pw_dir)
        }
        return realHome + path.dropFirst()
    }

    // MARK: - Ejecución de comandos

    /// Ejecuta un comando capturando stdout, stderr y el código de salida.
    ///
    /// Un exit-code distinto de cero NO lanza aquí: se devuelve para que la capa
    /// superior decida (p. ej. tmux "no server running" sale con código != 0 pero
    /// debe tratarse como lista vacía).
    ///
    /// `internal` (no `private`) para que la extensión de gestión de sesiones
    /// (`SSHSessionManagement.swift`) reutilice esta misma ejecución de comandos.
    func capture(
        _ client: SSHClient,
        command: String
    ) async throws -> (stdout: String, stderr: String, exitCode: Int) {
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        var exitCode = 0

        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer):
                    stdout.writeImmutableBuffer(buffer)
                case .stderr(let buffer):
                    stderr.writeImmutableBuffer(buffer)
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            // Salida con código != 0: capturamos el código; stdout/stderr ya recogidos.
            exitCode = failure.exitCode
        }

        return (String(buffer: stdout), String(buffer: stderr), exitCode)
    }
}
