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
import Citadel
import Crypto      // Curve25519.Signing.PrivateKey
import NIOCore     // ByteBuffer, String(buffer:)

/// Gestiona una conexión SSH a un host y lista sus sesiones tmux.
///
/// Es un `actor`: el `SSHClient` (no `Sendable`) queda protegido por el
/// aislamiento del actor, evitando accesos concurrentes a la conexión.
actor SSHService {

    // MARK: - Configuración

    /// Parámetros de conexión a un servidor.
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var username: String
        /// Ruta a la clave privada (admite `~`). Se lee en tiempo de conexión.
        var privateKeyPath: String
        /// Passphrase de la clave privada.
        ///
        /// 👉 PUNTO DE INYECCIÓN: si tu `id_ed25519` tiene passphrase, asígnala aquí
        ///    (o pásala desde la UI / Keychain). Por defecto `nil` = clave SIN passphrase.
        ///    Internamente se convierte a `Data(passphrase.utf8)` para Citadel.
        var passphrase: String?

        /// Servidor de desarrollo (Host "dev" de la config SSH del usuario).
        static let dev = Configuration(
            host: "100.86.237.26",
            port: 2222,
            username: "victalejo",
            privateKeyPath: "~/.ssh/id_ed25519",
            passphrase: nil // <- inyecta aquí la passphrase si la clave la requiere
        )
    }

    // MARK: - Errores

    enum SSHServiceError: LocalizedError {
        case keyUnreadable(path: String, underlying: Error)
        case keyParseFailed(underlying: Error)
        case commandFailed(exitCode: Int, message: String)
        case tmuxNotInstalled
        case installFailed(String)
        case configFailed(String)

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
        guard let client else { return }
        try? await client.close()
        self.client = nil
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
    private static func indicatesNoTmuxServer(stdout: String, stderr: String) -> Bool {
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
    private static func indicatesTmuxNotInstalled(
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

    // MARK: - Conexión

    /// Conexión SSH compartida. `internal` (no `private`) para que la extensión del
    /// terminal en vivo (`SSHTerminalSession.swift`) reutilice el mismo `SSHClient`.
    func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected {
            return client
        }

        let privateKey = try loadPrivateKey()
        let authentication = SSHAuthenticationMethod.ed25519(
            username: configuration.username,
            privateKey: privateKey
        )

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
        return client
    }

    /// Lee y parsea la clave Ed25519 OpenSSH del disco.
    private func loadPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        let path = (configuration.privateKeyPath as NSString).expandingTildeInPath

        let keyText: String
        do {
            keyText = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SSHServiceError.keyUnreadable(path: path, underlying: error)
        }

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
