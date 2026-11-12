//
//  MockSSHService.swift
//  ArgosTests
//
//  Doble de prueba de `SSHServicing`: permite ejercitar `SessionsViewModel` y el flujo
//  de bootstrap (verificar → instalar → configurar → listar) sin un servidor SSH real.
//
//  `@unchecked Sendable`: el estado mutable es de configuración fijada por la prueba antes
//  de usarse y consultada de forma secuencial; no hay concurrencia real en los tests.
//

import Foundation
@testable import Argos

final class MockSSHService: SSHServicing, @unchecked Sendable {

    // MARK: - Comportamiento configurable
    var tmuxInstalled = true
    var hasSudo = true
    var configExists = true
    var sessions: [TmuxSession] = []
    /// Si no es `nil`, `listSessions()` lanza este error (simula fallo de conexión).
    var listError: Error?
    /// Si no es `nil`, `killSession(named:)` lanza este error.
    var killError: Error?
    /// Si no es `nil`, `createSession(named:)` lanza este error.
    var createError: Error?

    // MARK: - Registro de llamadas (para aserciones)
    private(set) var installCalled = false
    private(set) var writeConfigCalled = false
    private(set) var clipboardForwardingCalled = false
    private(set) var createdNames: [String] = []
    private(set) var renamedTo: [String] = []
    private(set) var killedNames: [String] = []

    // MARK: - Bootstrap de tmux
    func isTmuxInstalled() async throws -> Bool { tmuxInstalled }
    func canUseSudoNonInteractive() async throws -> Bool { hasSudo }
    func installTmuxWithApt() async throws { installCalled = true; tmuxInstalled = true }
    func tmuxConfigExists() async throws -> Bool { configExists }
    func writeDefaultTmuxConfig() async throws { writeConfigCalled = true; configExists = true }
    func enableClipboardForwarding() async { clipboardForwardingCalled = true }

    // MARK: - Listado / CRUD de sesiones
    /// Se invoca al listar (para observar el estado del llamador en mitad de la operación).
    var onListSessions: () -> Void = {}

    func listSessions() async throws -> [TmuxSession] {
        onListSessions()
        if let listError { throw listError }
        return sessions
    }

    func createSession(named name: String) async throws {
        if let createError { throw createError }
        createdNames.append(name)
        sessions.append(TmuxSession(name: name, windowCount: 1, isAttached: false,
                                    createdAt: Date(timeIntervalSince1970: 0)))
    }

    func renameSession(from oldName: String, to newName: String) async throws {
        renamedTo.append(newName)
        if let index = sessions.firstIndex(where: { $0.name == oldName }) {
            let old = sessions[index]
            sessions[index] = TmuxSession(name: newName, windowCount: old.windowCount,
                                          isAttached: old.isAttached, createdAt: old.createdAt)
        }
    }

    func killSession(named name: String) async throws {
        if let killError { throw killError }
        killedNames.append(name)
        sessions.removeAll { $0.name == name }
    }

    // MARK: - Ventanas
    func listWindows(session: String) async throws -> [TmuxWindow] { [] }
    func selectWindow(session: String, index: Int) async throws {}
    func newWindow(session: String) async throws {}
    func newAgentWindow(session: String, agent: CodingAgent, directory: String?) async throws {}
    func installedCodingAgents() async throws -> Set<CodingAgent> { [] }
    func gitBranch(at path: String) async throws -> String? { nil }
    func renameWindow(session: String, index: Int, to name: String) async throws {}
    func setWindowColor(session: String, index: Int, color: WindowColor?) async throws {}
    func killWindow(session: String, index: Int) async throws {}
    func authorizeKey(line: String) async throws {}
    func revokeKey(comment: String) async throws {}
    func listAuthorizedDeviceKeys() async throws -> [AuthorizedDeviceKey] { [] }

    // MARK: - Paneles
    private(set) var splitVerticalCalls: [Bool] = []
    private(set) var selectedPaneDirections: [TmuxPaneDirection] = []
    private(set) var zoomPaneCalls = 0
    private(set) var killPaneCalls = 0

    func splitPane(session: String, vertical: Bool) async throws { splitVerticalCalls.append(vertical) }
    func selectPane(session: String, direction: TmuxPaneDirection) async throws {
        selectedPaneDirections.append(direction)
    }
    func zoomPane(session: String) async throws { zoomPaneCalls += 1 }
    func killPane(session: String) async throws { killPaneCalls += 1 }

    // MARK: - send-keys
    /// Registro de envíos: (sesión, texto, enter).
    private(set) var sentKeys: [(session: String, keys: String, enter: Bool)] = []
    func sendKeys(session: String, keys: String, enter: Bool) async throws {
        sentKeys.append((session, keys, enter))
    }

    // MARK: - Transferencia de archivos
    func resourceSample() async throws -> ServerResourceSample { throw ServerResourceError.unsupported }

    var claudeSnapshot = ClaudeActivitySnapshot.empty
    func claudeActivity() async throws -> ClaudeActivitySnapshot { claudeSnapshot }
    func claudeHooksInstalled() async throws -> Bool { false }
    func installClaudeHooks() async throws {}
    var claudeHookUpgrades = 0
    func upgradeClaudeHooksIfOutdated() async throws -> Bool { claudeHookUpgrades += 1; return false }

    var storedProjects: [Project] = []
    var panePaths: [String: String] = [:]
    var missingFolders: Set<String> = []
    private(set) var startedProjects: [(session: String, path: String, command: String?)] = []
    private(set) var stoppedSessions: [String] = []
    func loadProjects() async throws -> [Project] { storedProjects }
    func saveProjects(_ projects: [Project]) async throws { storedProjects = projects }
    func sessionFirstPanePaths() async throws -> [String: String] { panePaths }
    func startProject(sessionName: String, path: String, startupCommand: String?) async throws {
        if missingFolders.contains(path) { throw ProjectError.missingFolder(path) }
        startedProjects.append((sessionName, path, startupCommand))
        sessions.append(TmuxSession(name: sessionName, windowCount: 1, isAttached: false, createdAt: Date()))
    }
    // MARK: - Git
    var gitStatusResult: GitStatusResult = .notRepository
    var gitDiffResult: GitFileDiff = .empty
    /// Si no es `nil`, las operaciones git que escriben lanzan este error.
    var gitError: Error?
    private(set) var discardedChanges: [GitFileChange] = []
    private(set) var commits: [(message: String, paths: [String])] = []
    private(set) var pushes: [Bool] = []
    private(set) var pulls = 0
    private(set) var diffRequests: [GitFileChange] = []
    func gitStatus(at path: String) async throws -> GitStatusResult { gitStatusResult }
    func gitDiff(root: String, change: GitFileChange, hasCommits: Bool) async throws -> GitFileDiff {
        diffRequests.append(change)
        return gitDiffResult
    }
    func gitDiscard(root: String, change: GitFileChange) async throws {
        if let gitError { throw gitError }
        discardedChanges.append(change)
    }
    func gitCommit(root: String, message: String, changes: [GitFileChange]) async throws -> String {
        if let gitError { throw gitError }
        commits.append((message, GitCommands.commitPaths(changes)))
        return "[main abc1234] \(message)"
    }
    func gitPush(root: String, hasUpstream: Bool) async throws -> String {
        if let gitError { throw gitError }
        pushes.append(hasUpstream)
        return "ok"
    }
    var gitSummariesResult: [String: GitRepoSummary] = [:]
    private(set) var gitSummaryRequests: [[String]] = []
    func gitSummaries(paths: [String]) async throws -> [String: GitRepoSummary] {
        if let gitError { throw gitError }
        gitSummaryRequests.append(paths)
        return gitSummariesResult.filter { paths.contains($0.key) }
    }
    func gitPull(root: String) async throws -> String {
        if let gitError { throw gitError }
        pulls += 1
        return "Already up to date."
    }

    // MARK: - Worktrees
    var worktreeListing: GitWorktreeParser.ListResult = .notRepository
    private(set) var addedWorktrees: [GitWorktreeRequest] = []
    private(set) var removedWorktrees: [(path: String, force: Bool)] = []
    var addedWorktreePath: String?
    func gitWorktrees(at path: String) async throws -> GitWorktreeParser.ListResult { worktreeListing }
    func gitAddWorktree(_ request: GitWorktreeRequest) async throws -> String {
        if let gitError { throw gitError }
        addedWorktrees.append(request)
        return addedWorktreePath ?? request.path
    }
    func gitRemoveWorktree(repository: String, path: String, force: Bool) async throws {
        if let gitError { throw gitError }
        removedWorktrees.append((path, force))
    }

    // MARK: - GitHub
    var gitHubStatusResult: GitHubStatusResult = .notGitHub
    private(set) var gitHubStatusRequests: [String] = []
    var gitHubCreatedURL: URL? = URL(string: "https://github.com/o/r/pull/7")
    private(set) var createdPullRequests: [(root: String, draft: Bool)] = []
    private(set) var rerunRequests: [Int] = []
    var gitHubRepositoriesResult: GitHubParser.RepositoriesResult = .loaded([])
    private(set) var cloneRequests: [GitHubCloneRequest] = []
    var clonedPath = "/srv/clonado"
    func gitHubStatus(root: String) async throws -> GitHubStatusResult {
        gitHubStatusRequests.append(root)
        if let gitError { throw gitError }
        return gitHubStatusResult
    }
    func gitHubCreatePullRequest(root: String, draft: Bool) async throws -> URL? {
        if let gitError { throw gitError }
        createdPullRequests.append((root, draft))
        return gitHubCreatedURL
    }
    func gitHubRerunFailed(root: String, runID: Int) async throws {
        if let gitError { throw gitError }
        rerunRequests.append(runID)
    }
    func gitHubRepositories() async throws -> GitHubParser.RepositoriesResult {
        if let gitError { throw gitError }
        return gitHubRepositoriesResult
    }
    func gitHubClone(_ request: GitHubCloneRequest) async throws -> String {
        if let gitError { throw gitError }
        cloneRequests.append(request)
        return clonedPath
    }

    var remoteTree: [String: [RemoteFileEntry]] = [:]
    var remoteFiles: [String: Data] = [:]
    func listRemoteDirectory(_ path: String, root: String) async throws -> [RemoteFileEntry] {
        remoteTree[path] ?? []
    }
    func readRemoteFile(_ path: String, root: String, maxBytes: UInt64) async throws -> RemoteFileContent {
        let data = remoteFiles[path] ?? Data()
        return RemoteFileContent(data: data.prefix(Int(maxBytes)), size: UInt64(data.count),
                                 modified: nil, isTruncated: UInt64(data.count) > maxBytes)
    }
    func downloadRemoteFile(_ path: String, root: String, to localURL: URL) async throws {
        try (remoteFiles[path] ?? Data()).write(to: localURL)
    }
    func indexProjectFiles(root: String) async throws -> [String] {
        Array(remoteFiles.keys).map { RemotePath.relative($0, to: root) }.sorted()
    }
    var syncServerFiles: [SyncFile] = []
    var syncServerData: [String: Data] = [:]
    private(set) var uploadedSyncPaths: [String] = []
    private(set) var deletedSyncPaths: [String] = []
    func syncFileList(root: String) async throws -> [SyncFile] { syncServerFiles }
    func downloadSyncFile(root: String, file: SyncFile, to localURL: URL) async throws {
        try (syncServerData[file.path] ?? Data()).write(to: localURL)
    }
    func makeRemoteDirectories(root: String, relativeDirectories: [String]) async throws {}
    func uploadSyncFile(root: String, file: SyncFile, from localURL: URL) async throws {
        uploadedSyncPaths.append(file.path)
        syncServerData[file.path] = try Data(contentsOf: localURL)
        syncServerFiles.removeAll { $0.path == file.path }
        syncServerFiles.append(file)
    }
    func deleteRemoteSyncFile(root: String, relativePath: String) async throws {
        deletedSyncPaths.append(relativePath)
        syncServerFiles.removeAll { $0.path == relativePath }
    }
    func stopSession(named sessionName: String) async throws {
        stoppedSessions.append(sessionName)
        sessions.removeAll { $0.name == sessionName }
    }

    func uploadPastedFile(data: Data, fileExtension: String) async throws -> String { "" }
    func uploadDroppedFile(data: Data, originalName: String) async throws -> String { "" }
    func capturePaneText(session: String) async throws -> String { "" }

    // MARK: - Ciclo de vida / terminal
    func disconnect() async {}

    /// Orden de las llamadas de suspensión del keep-alive (`true` = suspender).
    private(set) var heartbeatSuspensions: [Bool] = []
    func suspendHeartbeat() async { heartbeatSuspensions.append(true) }
    func resumeHeartbeat() async { heartbeatSuspensions.append(false) }

    func attachTerminal(
        session name: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws {
        output.finish()
    }

    // MARK: - Panel de agente

    /// Ruta que devuelve `locateClaude` (nil simula "no instalado").
    var claudePath: String? = "/usr/bin/claude"
    /// Líneas NDJSON que `runAgentExec` emitirá por stdout al arrancar.
    var agentScript: [String] = []
    /// Líneas recibidas por stdin (prompts y control_response), para aserciones.
    private(set) var agentStdinLines: [String] = []
    /// Último comando recibido por `runAgentExec`.
    private(set) var lastAgentCommand: String?
    /// Todos los comandos recibidos por `runAgentExec`, en orden.
    private(set) var agentCommands: [String] = []
    /// Comandos del agente persistente recibidos y respuesta (stdout) a cada uno.
    private(set) var agentScripts: [String] = []
    var agentScriptOutput: (String) throws -> String = { _ in "" }

    func locateClaude() async throws -> String? { claudePath }

    var availableMemory: Int? = 8_000_000
    private(set) var killedAgentPIDs: [Int32] = []
    func killAgentProcess(pid: Int32) async { killedAgentPIDs.append(pid) }
    func availableMemoryKB() async throws -> Int? { availableMemory }

    /// Si el directorio remoto existe (por defecto sí).
    var directoryExists = true
    func remoteDirectoryExists(_ path: String) async throws -> Bool { directoryExists }

    /// Subcarpetas por ruta (para el selector). El mock resuelve `~` a /home/test.
    var remoteDirs: [String: [String]] = [:]
    func listRemoteDirectories(at path: String) async throws -> RemoteDirectoryListing {
        let resolved = (path == "~" || path.isEmpty) ? "/home/test" : path
        return RemoteDirectoryListing(path: resolved, subdirectories: remoteDirs[resolved] ?? [])
    }

    /// Estado de auth que devuelve el mock (por defecto: logueado con suscripción max).
    var authStatus: ClaudeAuthStatus? = ClaudeAuthStatus(
        loggedIn: true, subscriptionType: "max", email: "test@example.com"
    )
    func claudeAuthStatus() async throws -> ClaudeAuthStatus? { authStatus }

    /// Salida que emite el comando del PTY (p. ej. `claude auth login`).
    var commandOutput: [String] = []
    /// Si es `true`, el comando sigue vivo hasta que se cierre su entrada.
    var commandStaysOpen = false
    var commandError: Error?
    /// Se llama con cada texto tecleado en el PTY del comando.
    var onCommandInput: (String) -> Void = { _ in }
    private(set) var attachedCommands: [String] = []
    private(set) var commandInput: [String] = []

    func attachCommand(
        command: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws {
        defer { output.finish() }
        attachedCommands.append(command)
        if let commandError { throw commandError }
        for chunk in commandOutput { output.yield(Array(chunk.utf8)) }
        guard commandStaysOpen else { return }
        for await event in control {
            if case .input(let bytes) = event {
                let text = String(decoding: bytes, as: UTF8.self)
                commandInput.append(text)
                onCommandInput(text)
            }
        }
    }

    func runAgentExec(
        command: String,
        stdin: AsyncStream<[UInt8]>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws {
        lastAgentCommand = command
        agentCommands.append(command)
        for line in agentScript {
            output.yield(Array((line + "\n").utf8))
        }
        // Drena stdin (registrándolo) hasta que el llamador lo finalice con `stop()`.
        for await bytes in stdin {
            if let text = String(bytes: bytes, encoding: .utf8) {
                agentStdinLines.append(
                    contentsOf: text.split(whereSeparator: \.isNewline).map(String.init)
                )
            }
        }
        output.finish()
    }

    func runAgentScript(_ command: String) async throws -> String {
        agentScripts.append(command)
        return try agentScriptOutput(command)
    }

    // MARK: - Reenvío de puertos
    var listening: [ListeningPort] = []
    var forwards: [ActivePortForward] = []
    /// Si no es `nil`, `startPortForward` lanza este error.
    var forwardError: Error?
    /// Puertos locales «ocupados»: el mock asigna el siguiente libre.
    var busyLocalPorts: Set<Int> = []
    func listeningPorts() async throws -> [ListeningPort] { listening }
    func startPortForward(remotePort: Int, targetHost: String, preferredLocalPort: Int) async throws -> ActivePortForward {
        if let forwardError { throw forwardError }
        var local = preferredLocalPort
        while busyLocalPorts.contains(local) { local += 1 }
        let forward = ActivePortForward(id: UUID(), remotePort: remotePort, targetHost: targetHost, localPort: local)
        forwards.append(forward)
        return forward
    }
    func stopPortForward(id: UUID) async { forwards.removeAll { $0.id == id } }
    func activePortForwards() async -> [ActivePortForward] { forwards }
    var portRequests: [PortForwardRequest] = []
    private(set) var dismissedPortRequests: [Int] = []
    func pendingPortForwardRequests() async throws -> [PortForwardRequest] { portRequests }
    func dismissPortForwardRequest(port: Int) async {
        dismissedPortRequests.append(port)
        portRequests.removeAll { $0.port == port }
    }
}
