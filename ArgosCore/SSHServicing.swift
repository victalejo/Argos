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
    func renameWindow(session: String, index: Int, to name: String) async throws
    func setWindowColor(session: String, index: Int, color: WindowColor?) async throws
    func killWindow(session: String, index: Int) async throws

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

    // MARK: - Enviar al Mac / al servidor

    func syncFileList(root: String) async throws -> [SyncFile]
    func downloadSyncFile(root: String, file: SyncFile, to localURL: URL) async throws
    func makeRemoteDirectories(root: String, relativeDirectories: [String]) async throws
    func uploadSyncFile(root: String, file: SyncFile, from localURL: URL) async throws
    func deleteRemoteSyncFile(root: String, relativePath: String) async throws

    func uploadPastedFile(data: Data, fileExtension: String) async throws -> String
    func uploadDroppedFile(data: Data, originalName: String) async throws -> String

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
}

extension SSHService: SSHServicing {}
