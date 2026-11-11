//
//  SSHServicing.swift
//  Argos
//
//  Abstracción del servicio SSH para inyección de dependencias. Permite que el
//  ViewModel y el controlador del terminal reciban `any SSHServicing` y que las
//  pruebas inyecten un doble sin necesidad de un servidor SSH real.
//

import Foundation

/// Dirección para navegar entre paneles de tmux (mapea a `select-pane -U/-D/-L/-R`).
enum TmuxPaneDirection: String, Sendable, CaseIterable {
    case up, down, left, right

    /// Flag de `tmux select-pane` correspondiente.
    var selectPaneFlag: String {
        switch self {
        case .up: return "-U"
        case .down: return "-D"
        case .left: return "-L"
        case .right: return "-R"
        }
    }
}

/// Operaciones de un servicio SSH/tmux. `SSHService` (el actor real) la cumple;
/// los tests pueden proveer un mock.
protocol SSHServicing: Sendable {
    func listSessions() async throws -> [TmuxSession]
    func disconnect() async

    /// Pausa el keep-alive proactivo (heartbeat) mientras el Mac duerme: no genera
    /// tráfico SSH hasta `resumeHeartbeat()`. Las acciones del usuario siguen conectando.
    func suspendHeartbeat() async
    /// Reanuda el keep-alive al despertar y comprueba la conexión de inmediato.
    func resumeHeartbeat() async

    func isTmuxInstalled() async throws -> Bool
    func canUseSudoNonInteractive() async throws -> Bool
    func installTmuxWithApt() async throws
    func tmuxConfigExists() async throws -> Bool
    func writeDefaultTmuxConfig() async throws
    func enableClipboardForwarding() async

    func createSession(named name: String) async throws
    func renameSession(from oldName: String, to newName: String) async throws
    func killSession(named name: String) async throws

    func listWindows(session: String) async throws -> [TmuxWindow]
    func selectWindow(session: String, index: Int) async throws
    func newWindow(session: String) async throws
    /// Abre una ventana nueva con un agente de terminal (Claude Code, Codex, Grok).
    func newAgentWindow(session: String, agent: CodingAgent, directory: String?) async throws
    /// Agentes de terminal instalados en el servidor.
    func installedCodingAgents() async throws -> Set<CodingAgent>
    /// Rama git de `path` en el servidor (`nil` si no es un repositorio).
    func gitBranch(at path: String) async throws -> String?
    func renameWindow(session: String, index: Int, to name: String) async throws
    func setWindowColor(session: String, index: Int, color: WindowColor?) async throws
    func killWindow(session: String, index: Int) async throws
    /// Añade una línea a `~/.ssh/authorized_keys` del servidor.
    func authorizeKey(line: String) async throws
    /// Retira de `authorized_keys` las líneas con ese comentario.
    func revokeKey(comment: String) async throws
    /// Claves de dispositivos (iPhone/iPad) que Argos autorizó en el servidor.
    func listAuthorizedDeviceKeys() async throws -> [AuthorizedDeviceKey]

    func splitPane(session: String, vertical: Bool) async throws
    func selectPane(session: String, direction: TmuxPaneDirection) async throws
    func zoomPane(session: String) async throws
    func killPane(session: String) async throws

    func sendKeys(session: String, keys: String, enter: Bool) async throws

    /// Muestra de CPU, memoria, disco y procesos del servidor (monitor de recursos).
    func resourceSample() async throws -> ServerResourceSample

    /// Estado de Claude Code en los paneles de tmux (indicador por sesión/ventana).
    func claudeActivity() async throws -> ClaudeActivitySnapshot
    func claudeHooksInstalled() async throws -> Bool
    func installClaudeHooks() async throws
    /// Actualiza hooks de Argos de una versión anterior (si los hay). `true` si escribió.
    @discardableResult func upgradeClaudeHooksIfOutdated() async throws -> Bool

    // MARK: - Proyectos (carpetas con sesión tmux efímera)

    func loadProjects() async throws -> [Project]
    func saveProjects(_ projects: [Project]) async throws
    func sessionFirstPanePaths() async throws -> [String: String]
    func startProject(sessionName: String, path: String, startupCommand: String?) async throws
    func stopSession(named sessionName: String) async throws

    // MARK: - Explorador de archivos (solo lectura, SFTP)

    func listRemoteDirectory(_ path: String, root: String) async throws -> [RemoteFileEntry]
    func readRemoteFile(_ path: String, root: String, maxBytes: UInt64) async throws -> RemoteFileContent
    func indexProjectFiles(root: String) async throws -> [String]
    /// Copia un archivo del proyecto (entero) a `localURL` en el Mac.
    func downloadRemoteFile(_ path: String, root: String, to localURL: URL) async throws

    // MARK: - Cambios (git)

    /// Estado git de la carpeta (`.notRepository` si no está en un repositorio).
    func gitStatus(at path: String) async throws -> GitStatusResult
    func gitDiff(root: String, change: GitFileChange, hasCommits: Bool) async throws -> GitFileDiff
    /// Deja el archivo como en `HEAD` (o lo borra si no tenía seguimiento).
    func gitDiscard(root: String, change: GitFileChange) async throws
    /// Commit solo de `changes`. Devuelve el resumen de git (`[main abc123] mensaje`).
    func gitCommit(root: String, message: String, changes: [GitFileChange]) async throws -> String
    func gitPush(root: String, hasUpstream: Bool) async throws -> String
    func gitPull(root: String) async throws -> String
    /// Resumen git de varias carpetas en un solo comando (las que no son repo no aparecen).
    func gitSummaries(paths: [String]) async throws -> [String: GitRepoSummary]
    /// Worktrees del repositorio de `path` y sus ramas locales («Ramas en paralelo»).
    func gitWorktrees(at path: String) async throws -> GitWorktreeParser.ListResult
    /// Crea el worktree (y la rama, si es nueva); devuelve su ruta real.
    func gitAddWorktree(_ request: GitWorktreeRequest) async throws -> String
    /// Quita el worktree (`force`: aunque tenga cambios sin commit). La rama se conserva.
    func gitRemoveWorktree(repository: String, path: String, force: Bool) async throws

    // MARK: - GitHub (con el `gh` del servidor)

    /// PR de la rama actual y ejecuciones de Actions de HEAD.
    func gitHubStatus(root: String) async throws -> GitHubStatusResult
    /// Abre un PR de la rama actual (`--fill`); devuelve su URL.
    func gitHubCreatePullRequest(root: String, draft: Bool) async throws -> URL?
    /// Relanza los jobs fallidos de una ejecución de Actions.
    func gitHubRerunFailed(root: String, runID: Int) async throws
    /// Repositorios del usuario de `gh` (para clonar uno como proyecto).
    func gitHubRepositories() async throws -> GitHubParser.RepositoriesResult
    /// Clona y devuelve la ruta absoluta de la carpeta creada.
    func gitHubClone(_ request: GitHubCloneRequest) async throws -> String

    // MARK: - Enviar al Mac / al servidor

    func syncFileList(root: String) async throws -> [SyncFile]
    func downloadSyncFile(root: String, file: SyncFile, to localURL: URL) async throws
    func makeRemoteDirectories(root: String, relativeDirectories: [String]) async throws
    func uploadSyncFile(root: String, file: SyncFile, from localURL: URL) async throws
    func deleteRemoteSyncFile(root: String, relativePath: String) async throws

    func uploadPastedFile(data: Data, fileExtension: String) async throws -> String
    func uploadDroppedFile(data: Data, originalName: String) async throws -> String
    /// Texto del panel activo de la sesión con su historial (`tmux capture-pane`).
    func capturePaneText(session: String) async throws -> String

    func attachTerminal(
        session name: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws

    // MARK: - Panel de agente (Claude Code)

    /// Localiza el binario `claude` en el servidor (ruta absoluta), o `nil` si no está.
    func locateClaude() async throws -> String?

    /// Mata el `claude` de un agente (verificando que el PID sigue siendo un agente).
    func killAgentProcess(pid: Int32) async
    /// Memoria disponible del servidor en KB (`nil` si no se puede saber).
    func availableMemoryKB() async throws -> Int?

    /// ¿`path` existe como directorio en el servidor? (Validación previa al arranque.)
    func remoteDirectoryExists(_ path: String) async throws -> Bool

    /// Lista las subcarpetas de `path` en el servidor (para el selector visual).
    func listRemoteDirectories(at path: String) async throws -> RemoteDirectoryListing

    /// Estado de autenticación de `claude` en el servidor (`claude auth status --json`).
    /// `nil` si `claude` no está instalado en el servidor.
    func claudeAuthStatus() async throws -> ClaudeAuthStatus?

    /// Abre un PTY y corre un comando arbitrario (p. ej. `claude auth login`), con el
    /// mismo flujo bidireccional que `attachTerminal`.
    func attachCommand(
        command: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws

    /// Ejecuta `command` por un canal exec bidireccional (8-bit safe, sin PTY):
    /// escribe en stdin los bytes que llegan por `stdin` y entrega el stdout por
    /// `output`. Para manejar `claude` headless en modo stream-json.
    func runAgentExec(
        command: String,
        stdin: AsyncStream<[UInt8]>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws

    /// Ejecuta un comando corto del agente persistente (lanzar, enviar, listar,
    /// parar). Devuelve stdout; lanza si el código de salida no es 0.
    func runAgentScript(_ command: String) async throws -> String

    // MARK: - Reenvío de puertos (servidor → dispositivo)

    /// Puertos TCP en escucha en el servidor.
    func listeningPorts() async throws -> [ListeningPort]
    /// Abre `localhost:<local>` en el dispositivo hacia `targetHost:remotePort` del servidor.
    func startPortForward(remotePort: Int, targetHost: String, preferredLocalPort: Int) async throws -> ActivePortForward
    func stopPortForward(id: UUID) async
    /// Túneles activos (reabre los que perdieron la conexión).
    func activePortForwards() async -> [ActivePortForward]
    /// Solicitudes de Claude para abrir un puerto (`argos-ports open`), pendientes de confirmar.
    func pendingPortForwardRequests() async throws -> [PortForwardRequest]
    /// Retira una solicitud (aceptada o rechazada).
    func dismissPortForwardRequest(port: Int) async
}

extension SSHService: SSHServicing {}
