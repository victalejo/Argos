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

    var metricsHistory = ServerMetricsHistory()
    private(set) var metricsRequests: [ServerMetricsRange] = []
    private(set) var metricsActions: [String] = []
    func serverMetricsHistory(range: ServerMetricsRange) async throws -> ServerMetricsHistory {
        metricsRequests.append(range)
        return metricsHistory
    }
    func installServerMetrics() async throws -> ClaudeTaskTimer.Kind {
        metricsActions.append("install")
        metricsHistory.isInstalled = true
        metricsHistory.timer = .systemd
        return .systemd
    }
    func uninstallServerMetrics() async throws {
        metricsActions.append("uninstall")
        metricsHistory.isInstalled = false
    }
    var processSurvey = ClaudeProcessSurvey()
    var orphanKillOutcome: ClaudeOrphanKillOutcome = .killed
    private(set) var killedOrphans: [Int] = []
    func claudeProcessSurvey() async throws -> ClaudeProcessSurvey { processSurvey }
    func killClaudeOrphans(_ orphans: [ClaudeOrphan]) async throws -> [Int: ClaudeOrphanKillOutcome] {
        killedOrphans.append(contentsOf: orphans.map(\.pid))
        if orphanKillOutcome == .killed {
            let gone = Set(orphans.map(\.pid))
            processSurvey.processes.removeAll { gone.contains($0.pid) }
        }
        return Dictionary(uniqueKeysWithValues: orphans.map { ($0.pid, orphanKillOutcome) })
    }

    var claudeSnapshot = ClaudeActivitySnapshot.empty
    func claudeActivity() async throws -> ClaudeActivitySnapshot { claudeSnapshot }
    func claudeHooksInstalled() async throws -> Bool { false }
    func installClaudeHooks() async throws {}
    var claudeHookUpgrades = 0
    func upgradeClaudeHooksIfOutdated() async throws -> Bool { claudeHookUpgrades += 1; return false }
    var claudeLimitsActive = false
    func claudeLimitsState() async throws -> ClaudeLimitsInstallState { claudeLimitsActive ? .active : .inactive }
    func installClaudeLimits() async throws { claudeLimitsActive = true }
    func uninstallClaudeLimits() async throws { claudeLimitsActive = false }
    private(set) var claudeUsageStarts = 0
    /// Lecturas sucesivas del uso (la última se repite).
    var claudeUsageSnapshots: [ClaudeUsageSnapshot] = [ClaudeUsageSnapshot(status: .never, records: [])]
    func startClaudeUsageIndex() async throws { claudeUsageStarts += 1 }
    private(set) var enqueuedTasks: [(ClaudeTaskRequest, String)] = []
    var tasks: [ClaudeTask] = []
    private(set) var taskActions: [String] = []
    func ensureTaskDispatcher() async throws {}
    func enqueueTask(_ request: ClaudeTaskRequest, projectPath: String) async throws { enqueuedTasks.append((request, projectPath)) }
    func listTasks() async throws -> [ClaudeTask] { tasks }
    func cancelTask(_ task: ClaudeTask) async throws { taskActions.append("cancel \(task.folder)") }
    func retryTask(_ task: ClaudeTask) async throws { taskActions.append("retry \(task.folder)") }
    func pushTaskAnyway(_ task: ClaudeTask) async throws { taskActions.append("push-anyway \(task.folder)") }
    var budgetReading = ClaudeBudgetReading(output: "")
    private(set) var savedBudgets: [(ClaudeProjectBudget, String)] = []
    func readProjectBudget(projectKey: String) async throws -> ClaudeBudgetReading { budgetReading }
    var budgetTimer: ClaudeTaskTimer.Kind = .systemd
    func saveProjectBudget(_ budget: ClaudeProjectBudget, projectKey: String) async throws -> ClaudeTaskTimer.Kind? {
        savedBudgets.append((budget, projectKey))
        return budget.isEmpty ? nil : budgetTimer
    }
    var schedules: [ClaudeSchedule] = []
    func saveSchedule(_ schedule: ClaudeSchedule) async throws -> ClaudeTaskTimer.Kind {
        schedules.removeAll { $0.id == schedule.id }
        schedules.append(schedule)
        return .launchd
    }
    func listSchedules(projects: [Project]) async throws -> [ClaudeSchedule] { schedules }
    func deleteSchedule(id: String) async throws { schedules.removeAll { $0.id == id } }
    func runScheduleNow(id: String) async throws { taskActions.append("run \(id)") }
    func taskTimerStatus() async throws -> ClaudeTaskTimer.Kind { schedules.isEmpty ? .none : .launchd }
    func readClaudeUsage() async throws -> ClaudeUsageSnapshot {
        claudeUsageSnapshots.count > 1 ? claudeUsageSnapshots.removeFirst() : claudeUsageSnapshots[0]
    }

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
        // Como el script real (`has-session … && exit 0`): si ya existe, no hace nada.
        if sessions.contains(where: { $0.name == sessionName }) { return }
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
    /// Huella por ruta para `gitFingerprints` (por defecto, "fp").
    var gitFingerprintByPath: [String: String] = [:]
    func gitFingerprints(root: String, changes: [GitFileChange], hasCommits: Bool) async throws -> [String] {
        changes.map { gitFingerprintByPath[$0.path] ?? "fp" }
    }
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
    /// Las subidas llegan desde tareas en paralelo (`ProjectSyncEngine`): sin cerrojo, dos
    /// escrituras a la vez en estos diccionarios perdían una (test intermitente en la CI).
    private let syncLock = NSLock()
    func uploadSyncFile(root: String, file: SyncFile, from localURL: URL) async throws {
        let data = try Data(contentsOf: localURL)
        syncLock.withLock {
            uploadedSyncPaths.append(file.path)
            syncServerData[file.path] = data
            syncServerFiles.removeAll { $0.path == file.path }
            syncServerFiles.append(file)
        }
    }
    func deleteRemoteSyncFile(root: String, relativePath: String) async throws {
        syncLock.withLock {
            deletedSyncPaths.append(relativePath)
            syncServerFiles.removeAll { $0.path == relativePath }
        }
    }
    func stopSession(named sessionName: String) async throws {
        stoppedSessions.append(sessionName)
        sessions.removeAll { $0.name == sessionName }
    }

    /// Subidas al `/tmp` del servidor: cada una informa del progreso a mitad y al final.
    /// `uploadGate`, si está, retiene la subida hasta que se le da paso (tests de la cola).
    private(set) var uploadedNames: [String] = []
    var uploadError: Error?
    var uploadGate: (@Sendable (String) async -> Void)?
    func uploadPastedFile(data: Data, fileExtension: String, progress: UploadProgressHandler?) async throws -> String {
        try await fakeUpload(name: "pasted.\(fileExtension)", data: data, progress: progress)
    }
    func uploadDroppedFile(data: Data, originalName: String, progress: UploadProgressHandler?) async throws -> String {
        try await fakeUpload(name: originalName, data: data, progress: progress)
    }
    private func fakeUpload(name: String, data: Data, progress: UploadProgressHandler?) async throws -> String {
        progress?(data.count / 2)
        await uploadGate?(name)
        try Task.checkCancellation()
        if let uploadError { throw uploadError }
        progress?(data.count)
        uploadedNames.append(name)
        return "/tmp/argos-test-\(name)"
    }
    func capturePaneText(session: String) async throws -> String { "" }

    // MARK: - Ciclo de vida / terminal
    func disconnect() async {}

    /// Orden de las llamadas de suspensión del keep-alive (`true` = suspender).
    private(set) var heartbeatSuspensions: [Bool] = []
    func suspendHeartbeat() async { heartbeatSuspensions.append(true) }
    func resumeHeartbeat() async { heartbeatSuspensions.append(false) }

    // MARK: - Salud de la conexión
    private(set) var healthResets = 0
    func resetConnectionHealth() async { healthResets += 1 }
    func checkConnectionNow(timeout: Duration) async -> Bool { true }

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
    // Lo del agente SÍ se usa en paralelo: cada pestaña del panel ejecuta su `runAgentExec`
    // en su propia tarea (fuera del hilo principal) y todas registran a la vez. Sin
    // cerrojo, varias pestañas escribiendo en los mismos arrays era una carrera de datos
    // que podía tumbar el test de forma intermitente.
    private let agentLock = NSLock()
    private var agentState = AgentRecording()

    private struct AgentRecording {
        var script: [String] = []
        var stdinLines: [String] = []
        var lastCommand: String?
        var commands: [String] = []
        var scripts: [String] = []
        var killedPIDs: [Int32] = []
    }

    private func withAgentState<T>(_ body: (inout AgentRecording) -> T) -> T {
        agentLock.lock()
        defer { agentLock.unlock() }
        return body(&agentState)
    }

    /// Líneas NDJSON que `runAgentExec` emitirá por stdout al arrancar.
    var agentScript: [String] {
        get { withAgentState { $0.script } }
        set { withAgentState { $0.script = newValue } }
    }
    /// Líneas recibidas por stdin (prompts y control_response), para aserciones.
    var agentStdinLines: [String] { withAgentState { $0.stdinLines } }
    /// Último comando recibido por `runAgentExec`.
    var lastAgentCommand: String? { withAgentState { $0.lastCommand } }
    /// Todos los comandos recibidos por `runAgentExec`, en orden.
    var agentCommands: [String] { withAgentState { $0.commands } }
    /// Comandos del agente persistente recibidos y respuesta (stdout) a cada uno.
    var agentScripts: [String] { withAgentState { $0.scripts } }
    var agentScriptOutput: (String) throws -> String = { _ in "" }

    func locateClaude() async throws -> String? { claudePath }

    var availableMemory: Int? = 8_000_000
    var killedAgentPIDs: [Int32] { withAgentState { $0.killedPIDs } }
    func killAgentProcess(pid: Int32) async { withAgentState { $0.killedPIDs.append(pid) } }
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
        let script = withAgentState { state -> [String] in
            state.lastCommand = command
            state.commands.append(command)
            return state.script
        }
        for line in script {
            output.yield(Array((line + "\n").utf8))
        }
        // Drena stdin (registrándolo) hasta que el llamador lo finalice con `stop()`: la
        // «ejecución» queda suspendida aquí, así que la sesión sigue viva hasta entonces.
        for await bytes in stdin {
            if let text = String(bytes: bytes, encoding: .utf8) {
                let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                withAgentState { $0.stdinLines.append(contentsOf: lines) }
            }
        }
        output.finish()
    }

    func runAgentScript(_ command: String) async throws -> String {
        withAgentState { $0.scripts.append(command) }
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

    /// Lectura de memoria que devuelve la sección `memory` del sondeo (`nil` = servidor sin
    /// /proc/meminfo).
    var memoryReading: ServerMemoryReading?

    func workspacePoll(_ sections: Set<WorkspacePollSection>) async throws -> WorkspacePollOutput {
        var output = WorkspacePollOutput()
        if sections.contains(.claude) { output.claude = try await claudeActivity() }
        if sections.contains(.sessions) {
            do {
                output.sessions = .sessions(try await listSessions())
            } catch SSHService.SSHServiceError.tmuxNotInstalled {
                output.sessions = .tmuxMissing
            }
        }
        if sections.contains(.ports) { output.portRequests = try await pendingPortForwardRequests() }
        if sections.contains(.memory) { output.memory = memoryReading }
        return output
    }
    func dismissPortForwardRequest(port: Int) async {
        dismissedPortRequests.append(port)
        portRequests.removeAll { $0.port == port }
    }
}
