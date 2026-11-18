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
@preconcurrency import Citadel
import Crypto      // Curve25519.Signing.PrivateKey
import NIOCore     // ByteBuffer, String(buffer:)
import NIOSSH      // NIOSSHError (canal rechazado)

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
        /// No hay contraseña con la que autenticar (no guardada, o el Llavero aún no se
        /// puede leer porque el dispositivo no se ha desbloqueado desde que arrancó).
        case credentialUnavailable

        var errorDescription: String? {
            switch self {
            case .keyUnreadable(let path, _):
                #if os(iOS)
                return "No se pudo leer la clave privada de este servidor. " + ImportedKeyStore.missingKeyHint
                #else
                let hint = SSHDirectoryAccess.unreadableKeyHint(path: path, hasGrant: SSHDirectoryAccess.hasGrant())
                return ["No se pudo leer la clave privada en \(path).", hint].compactMap { $0 }.joined(separator: " ")
                #endif
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
            case .credentialUnavailable:
                return "No hay contraseña guardada para este servidor. Edítalo y vuelve a escribirla."
            }
        }
    }

    /// Mensaje accionable cuando tmux falta y no hay sudo sin contraseña: lo resuelve
    /// el usuario fuera de la app (la app NUNCA pide ni guarda la contraseña de sudo).
    static let manualInstallInstruction =
        "tmux no está instalado y tu usuario no tiene sudo sin contraseña. "
        + "Instálalo con: sudo apt install tmux"

    // MARK: - Estado

    let configuration: Configuration
    /// Conexión compartida de comandos cortos. `internal` para las extensiones del actor.
    var client: SSHClient?

    /// Cliente SFTP persistente del explorador de archivos (abrir uno por operación
    /// sería lento) y la conexión SSH a la que pertenece (al reconectar, se reabre).
    var fileSFTP: SFTPClient?
    var fileSFTPOwner: ObjectIdentifier?
    /// Tope de canales cortos simultáneos en la conexión compartida (ver `ChannelGate`).
    nonisolated let channelGate = ChannelGate()
    /// Apertura en curso del SFTP compartido: las transferencias en paralelo la esperan
    /// en vez de abrir cada una su canal (quedaban huérfanos y agotaban `MaxSessions`).
    var fileSFTPOpening: Task<SFTPClient, Error>?

    /// Tarea de heartbeat de la conexión actual (keep-alive). Ver `startHeartbeat`.
    var heartbeatTask: Task<Void, Never>?
    /// `true` mientras el Mac duerme: el heartbeat no toca la red hasta
    /// `resumeHeartbeat()`. Idea original de Kevin Jovy (PR #2).
    var heartbeatSuspended = false
    /// Conexiones dedicadas abiertas para canales de larga duración (terminales, agente).
    /// Se guardan para cerrarlas todas en `disconnect()`.
    var dedicatedClients: [UUID: SSHClient] = [:]
    /// Vigilantes de las conexiones dedicadas y de los túneles (ver `SSHConnectionMonitor`).
    var linkMonitors: [UUID: Task<Void, Never>] = [:]
    /// Conexiones dedicadas que el vigilante cerró por no responder: su dueño recibe
    /// `SSHConnectionError.connectionLost` (y reconecta) aunque el canal acabara «limpio».
    var lostLinks: Set<UUID> = []
    /// Salud de la conexión: bloqueo por credenciales y espera entre reintentos de red.
    var health = ConnectionHealth()
    /// Error que bloqueó los reintentos (se relanza tal cual: la UI distingue host key).
    var lastBlockingError: Error?
    /// Ritmo de los vigilantes y umbrales (inyectable en los tests).
    var monitorPolicy = ConnectionMonitorPolicy.standard
    /// Última actividad de la compartida: con tráfico reciente no hace falta latido.
    nonisolated let sharedActivity = LinkActivity()
    /// Actividad de cada conexión dedicada (la anota su dueño al recibir datos).
    var linkActivities: [UUID: LinkActivity] = [:]
    /// Sondeos lanzados por los vigilantes de conexiones dedicadas (para los tests).
    var linkProbeCount = 0
    /// Latidos lanzados sobre la compartida (para los tests).
    var sharedProbeCount = 0
    /// Comandos con turno ocupado y, de ellos, los que vencieron con el canal aún abierto.
    var heldCommands: Set<UUID> = []
    var abandonedCommands: Set<UUID> = []
    /// Túneles de reenvío de puertos activos (ver `SSHPortForwarding.swift`).
    var portForwards: [UUID: PortForwardRuntime] = [:]
    /// Vigilante de los túneles: cierra los inactivos y renueva su archivo en el servidor.
    var portForwardWatcher: Task<Void, Never>?
    /// La skill/script `argos-ports` ya se comprobó en esta conexión.
    var portsToolChecked = false
    /// Última vez que se publicó el estado de los túneles en el servidor.
    var portForwardsPublishedAt: Date?
    /// Túneles caídos que aún no se han podido reabrir (se reintenta en cada pasada).
    var brokenPortForwards: [UUID: ActivePortForward] = [:]
    /// Hay una reapertura de túneles en curso (el actor es reentrante en cada `await`).
    var isReopeningPortForwards = false
    /// Apertura en curso de la conexión compartida: quien llegue mientras tanto la espera
    /// en vez de abrir otra (que quedaría huérfana).
    private var connecting: Task<SSHClient, Error>?
    /// Sube en cada `disconnect()`: una apertura que termina después de desconectar no
    /// debe instalarse (dejaría una conexión y un heartbeat sin dueño).
    var connectionEpoch = 0

    /// Formato exacto requerido para `tmux list-sessions -F`.
    static let sessionFormat =
        "#{session_name}|#{session_windows}|#{session_attached}|#{session_created}"

    /// `-u`: salida en UTF-8 aunque el servidor no tenga locale (macOS, Linux mínimo):
    /// sin él tmux cambia cada carácter no ASCII por «_» y una sesión «diseño» se
    /// listaría como «dise_o», un nombre que luego no encuentra ningún `-t =nombre`.
    private static var listSessionsCommand: String {
        "tmux -u list-sessions -F '\(sessionFormat)'"
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
        // Es el sondeo más frecuente: con plazo también en el servidor (ver RemoteTimeout).
        let result = try await capture(client, command: RemoteTimeout.wrap(Self.listSessionsCommand))

        if result.exitCode != 0 {
            // 0) El plazo remoto (`timeout`) mató un tmux colgado: es un plazo vencido, no
            //    un fallo de tmux (si no, la interfaz decía «no devolvió detalles»).
            if result.exitCode == RemoteTimeout.expiredExitCode, result.stdout.isEmpty, result.stderr.isEmpty {
                throw SSHConnectionError.commandTimedOut(.seconds(RemoteTimeout.pollSeconds))
            }
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
        connectionEpoch += 1
        connecting?.cancel()
        connecting = nil
        stopHeartbeat()
        await stopAllPortForwards()
        stopAllLinkMonitors()
        let dedicated = dedicatedClients.values
        dedicatedClients.removeAll()
        linkActivities.removeAll()
        for dedicatedClient in dedicated {
            try? await dedicatedClient.close()
        }
        fileSFTPOpening?.cancel()
        fileSFTPOpening = nil
        try? await fileSFTP?.close()
        fileSFTP = nil
        fileSFTPOwner = nil
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
        // Largo a propósito: `apt-get update` + instalar pueden tardar minutos.
        let result = try await capture(client, command: install, timeout: .long)

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
    /// puedan copiar al portapapeles del Mac, y declara que el terminal de Argos admite
    /// color verdadero (afecta a los clientes que se enganchen después). Best-effort: si no
    /// hay servidor tmux o el comando falla, se ignora silenciosamente (no debe bloquear la
    /// conexión).
    func enableClipboardForwarding() async {
        guard let client = try? await connectedClient() else { return }
        let command =
            "tmux set -g set-clipboard on 2>/dev/null; "
            // Solo una vez: `-ga` acumularía una copia del override en cada conexión.
            + "tmux show -g terminal-overrides 2>/dev/null | grep -q ':Ms=' "
            + "|| tmux set -ga terminal-overrides ',*:Ms=\\E]52;%p1%s;%p2%s\\007' 2>/dev/null; "
            // Color verdadero: sin `Tc`, tmux rebaja los colores RGB de las apps a la paleta
            // de 256. Solo se añade una vez (`-ga` acumularía una copia por conexión).
            + "tmux show -g terminal-overrides 2>/dev/null | grep -q 'xterm-256color:Tc' "
            + "|| tmux set -ga terminal-overrides ',xterm-256color:Tc' 2>/dev/null; true"
        _ = try? await capture(client, command: command)
    }

    // MARK: - Conexión

    /// Conexión SSH compartida. `internal` (no `private`) para que la extensión del
    /// terminal en vivo (`SSHTerminalSession.swift`) reutilice el mismo `SSHClient`.
    func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected {
            return client
        }
        // El actor es reentrante: sin esto, dos llamadas simultáneas (sondeos, panel
        // git…) abrirían una conexión cada una y la primera quedaría sin dueño.
        if let connecting {
            do {
                return try await connecting.value
            } catch where ConnectionHealth.joinerShouldRetry(after: error, priority: ConnectionPriority.current) {
                // El intento era de un sondeo y se quedó en la espera: el usuario no espera.
                if let client, client.isConnected { return client }
            }
        }

        let epoch = connectionEpoch
        let attempt = Task { try await self.openClient() }
        connecting = attempt
        defer { if connecting == attempt { connecting = nil } }
        let fresh = try await attempt.value
        // Desconectaron mientras se abría: esta conexión ya no la quiere nadie.
        guard epoch == connectionEpoch else {
            Task { try? await fresh.close() }
            throw CancellationError()
        }
        replaceSharedClient(with: fresh)
        // El tope adaptativo de canales se recuerda solo para la conexión en la que se aprendió.
        await channelGate.resetLimit()
        Log.ssh.notice("Conexión SSH establecida con \(self.configuration.host, privacy: .public):\(self.configuration.port)")
        startHeartbeat()
        return fresh
    }

    /// Cambia la conexión compartida cerrando la anterior (el `SSHClient` de Citadel no se
    /// cierra solo al soltarlo). Cerrarla hace fallar los comandos que siguieran colgados
    /// en ella.
    func replaceSharedClient(with fresh: SSHClient?) {
        let stale = client
        client = fresh
        guard let stale, stale !== fresh else { return }
        Task { try? await stale.close() }
    }

    /// Ejecuta `body` sobre una conexión SSH PROPIA que se cierra al terminar.
    ///
    /// OpenSSH limita los canales por conexión (`MaxSessions`, 10 por defecto). Si cada
    /// terminal y cada agente abriera su canal en la conexión compartida, con varios
    /// proyectos en marcha se superaría el límite y el servidor rechazaría los canales
    /// nuevos ("no more sessions" → `NIOSSHError`). Los canales de larga duración usan
    /// por eso una conexión dedicada; la compartida queda para comandos cortos.
    ///
    /// Un vigilante la sondea (ver `ConnectionMonitorPolicy`): si deja de responder (cambio de
    /// red, reposo largo) la cierra y `body` termina con `SSHConnectionError.connectionLost`,
    /// para que su dueño reconecte con su propio backoff en vez de quedarse «conectado».
    func withDedicatedClient(_ body: (SSHClient) async throws -> Void) async throws {
        try await withDedicatedClient { client, _ in try await body(client) }
    }

    /// Igual, y además entrega la `LinkActivity` de la conexión: quien la usa la toca al
    /// recibir datos, y mientras haya tráfico reciente el vigilante no gasta un canal en
    /// sondearla (con `MaxSessions 1` ni siquiera podría).
    func withDedicatedClient(_ body: (SSHClient, LinkActivity) async throws -> Void) async throws {
        let id = UUID()
        let client = try await openClient()
        let activity = LinkActivity()
        dedicatedClients[id] = client
        linkActivities[id] = activity
        startLinkMonitor(id)
        Log.ssh.debug("Conexión dedicada abierta (\(self.dedicatedClients.count) activas)")
        do {
            try await body(client, activity)
        } catch {
            let lost = await closeDedicatedClient(id)
            if lost, !(error is CancellationError) { throw SSHConnectionError.connectionLost }
            throw error
        }
        if await closeDedicatedClient(id) { throw SSHConnectionError.connectionLost }
    }

    /// Cierra la conexión dedicada. Devuelve si el vigilante la había dado por perdida.
    private func closeDedicatedClient(_ id: UUID) async -> Bool {
        stopLinkMonitor(id)
        linkActivities.removeValue(forKey: id)
        let lost = lostLinks.remove(id) != nil
        guard let client = dedicatedClients.removeValue(forKey: id) else { return lost }
        try? await client.close()
        return lost
    }

    /// Abre y autentica una conexión nueva (TOFU + clave/Keychain), sin compartirla.
    /// `internal`: los túneles de puertos abren la suya (`SSHPortForwarding.swift`).
    ///
    /// Respeta la salud de la conexión: con credenciales rechazadas no toca la red hasta
    /// `resetConnectionHealth()`, y tras un fallo de red los sondeos de fondo esperan.
    func openClient() async throws -> SSHClient {
        try admitConnectionAttempt()
        do {
            let fresh = try await connectNewClient()
            health = health.recordingSuccess()
            lastBlockingError = nil
            return fresh
        } catch {
            recordConnectionFailure(error)
            throw error
        }
    }

    private func connectNewClient() async throws -> SSHClient {
        let authentication = try makeAuthenticationMethod()

        // Verificación de host key con Trust-On-First-Use (estilo known_hosts).
        // NO usamos `.acceptAnything()`: dejaría la conexión expuesta a MitM, algo
        // crítico ahora que la app puede ejecutar comandos privilegiados (instalar tmux).
        let hostKeyValidator = TOFUHostKeyValidator(
            host: configuration.host,
            port: configuration.port
        )

        return try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: authentication,
            hostKeyValidator: .custom(hostKeyValidator),
            reconnect: .never
        )
    }
}
