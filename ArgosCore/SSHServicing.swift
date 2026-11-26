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
    /// Statusline de Argos que guarda los límites de uso de Claude (ver `ClaudeLimitsInstaller`).
    func claudeLimitsState() async throws -> ClaudeLimitsInstallState
    func installClaudeLimits() async throws
    func uninstallClaudeLimits() async throws
    /// Índice de uso de tokens de Claude (ver `ClaudeUsageIndex`).
    func startClaudeUsageIndex() async throws
    func readClaudeUsage() async throws -> ClaudeUsageSnapshot
    /// Cola de encargos (ver `ClaudeTaskScript` y `docs/encargos.md`).
    func ensureTaskDispatcher() async throws
    func enqueueTask(_ request: ClaudeTaskRequest, projectPath: String) async throws
    func listTasks() async throws -> [ClaudeTask]
    func cancelTask(_ task: ClaudeTask) async throws
    func retryTask(_ task: ClaudeTask) async throws

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

    /// Sube a una ruta privada de `/tmp`; `progress` recibe los bytes ya enviados.
    func uploadPastedFile(data: Data, fileExtension: String, progress: UploadProgressHandler?) async throws -> String
    func uploadDroppedFile(data: Data, originalName: String, progress: UploadProgressHandler?) async throws -> String
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

    // MARK: - Salud de la conexión

    /// Acción explícita del usuario: olvida el bloqueo por credenciales rechazadas o host
    /// key cambiada y la espera entre reintentos; el próximo intento va a la red.
    func resetConnectionHealth() async
    /// Comprueba ya la conexión compartida con plazo corto; si no responde la descarta (la
    /// próxima operación reconecta) y revisa las dedicadas. `true` si respondió.
    @discardableResult func checkConnectionNow(timeout: Duration) async -> Bool

    // MARK: - Datos seguros: projects.json, envío atómico y huellas de git

    /// Proyectos con avisos (entradas ilegibles apartadas, formato más nuevo).
    func loadProjectsReport() async throws -> ProjectsLoadReport
    /// Lee-modifica-escribe projects.json sin pisar cambios ajenos (ver `ProjectsUpdater`).
    func updateProjects(_ transform: @escaping @Sendable ([Project]) throws -> [Project]) async throws -> ProjectsLoadReport
    /// Sustituye projects.json por su copia `.argos-backup` (el dañado queda en `.argos-damaged`).
    func restoreProjectsBackup() async throws -> ProjectsLoadReport
    /// Sube a `<ruta>.argos-up` sin colocarlo (ver `SyncStaging`).
    func stageSyncFile(root: String, file: SyncFile, from localURL: URL) async throws
    /// Coloca con `mv -f` los archivos ya subidos (y crea los enlaces).
    func placeStagedSyncFiles(root: String, files: [SyncFile]) async throws
    func discardStagedSyncFiles(root: String, paths: [String]) async throws
    func removeStaleSyncTemporaries(root: String) async throws
    /// Huella barata (cksum del diff) de cada cambio, en el mismo orden.
    func gitFingerprints(root: String, changes: [GitFileChange], hasCommits: Bool) async throws -> [String]

    // MARK: - Sondeo agrupado (WorkspacePoller)

    /// Una vuelta del sondeo en un solo comando: estado de Claude, sesiones y solicitudes
    /// de puertos (ver `WorkspacePollCommand`). Hay una implementación por defecto con las
    /// llamadas sueltas (`SSHWorkspacePoll.swift`) para los dobles de prueba.
    func workspacePoll(_ sections: Set<WorkspacePollSection>) async throws -> WorkspacePollOutput
    /// Desconecta y no vuelve a conectar nunca (su view model se descartó). Por defecto,
    /// `disconnect()` (`SSHServiceRetirement.swift`).
    func retire() async

    // MARK: Puntos de restauración

    /// Ejecuta un comando de `CheckpointCommands` (plazo largo). No lanza por el código de
    /// salida. Implementación por defecto (lanza) para los dobles en `SSHCheckpoints.swift`.
    func runCheckpointCommand(_ command: String) async throws -> CheckpointCommandOutput
    /// ¿Están el hook de captura y su script, en su versión actual?
    func checkpointHookInstalled() async throws -> Bool
    /// Instala el hook de captura (solo al activar los puntos en un proyecto).
    func installCheckpointHook() async throws
    /// Quita el hook de captura y su script del servidor.
    func uninstallCheckpointHook() async throws
}

extension SSHServicing {
    /// `checkConnectionNow(timeout:)` con el plazo corto por defecto.
    @discardableResult
    func checkConnectionNow() async -> Bool {
        await checkConnectionNow(timeout: SSHService.quickCheckTimeout)
    }
}

extension SSHService: SSHServicing {}
