//
//  ClaudeTasksModel.swift
//  ArgosCore
//
//  Pantalla «Encargos» de un proyecto (Mac e iPhone/iPad): la cola de ese proyecto, añadir
//  un encargo y cancelar o reintentar. La cola avanza sola en el servidor (despachador +
//  hooks); aquí solo se lee cada pocos segundos mientras la pantalla está abierta.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeTasksModel {

    private(set) var tasks: [ClaudeTask] = []
    private(set) var isLoading = true
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// Los hooks del indicador no están puestos: sin ellos la cola no avanza sola.
    private(set) var needsHooks = false

    // Borrador del encargo nuevo.
    var draft = ""
    var window: Int
    var cleanContext = false
    var commit = false
    /// En un agente aparte, en su propio worktree y rama (no en la terminal).
    var inAgent = false

    /// Ventanas del proyecto con Claude (índice → estado), para elegir dónde.
    let claudeWindows: [Int: ClaudeActivity]

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored let project: Project
    @ObservationIgnored private let serverID: Server.ID
    @ObservationIgnored private let refreshInterval: Duration

    /// Cada cuánto se relee la cola con la pantalla abierta.
    static let refreshInterval: Duration = .seconds(5)
    /// Terminados que se enseñan.
    static let visibleFinished = 10

    init(
        service: any SSHServicing,
        serverID: Server.ID,
        project: Project,
        claudeWindows: [Int: ClaudeActivity],
        refreshInterval: Duration = ClaudeTasksModel.refreshInterval
    ) {
        self.service = service
        self.serverID = serverID
        self.project = project
        self.claudeWindows = claudeWindows
        self.refreshInterval = refreshInterval
        self.window = Self.suggestedWindow(claudeWindows)
    }

    /// La ventana libre (Claude terminó) con número más bajo; si no, la primera con Claude.
    static func suggestedWindow(_ windows: [Int: ClaudeActivity]) -> Int {
        windows.filter { $0.value == .done }.keys.min() ?? windows.keys.min() ?? 0
    }

    private var key: String { ClaudeUsageProjects.key(forPath: project.path) }

    var openTasks: [ClaudeTask] { tasks.filter { $0.state?.isOpen ?? false } }
    var finishedTasks: [ClaudeTask] {
        Array(tasks.filter { !($0.state?.isOpen ?? false) }.reversed().prefix(Self.visibleFinished))
    }
    var canAdd: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking }

    /// Lee la cola y la relee mientras la tarea viva (se cancela al cerrar la pantalla).
    func watch() async {
        do {
            needsHooks = try await !ConnectionPriority.background { try await self.service.claudeHooksInstalled() }
        } catch {
            Log.ssh.notice("Encargos: no se pudo comprobar el indicador: \(error.userMessage, privacy: .public)")
        }
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: refreshInterval)
        }
    }

    func reload() async {
        do {
            let all = try await ConnectionPriority.background { try await self.service.listTasks() }
            tasks = all.filter { $0.projectKey == key }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Encargos: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
        isLoading = false
    }

    func add() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        var request = ClaudeTaskRequest(
            prompt: prompt, session: project.sessionName, window: window, cleanContext: cleanContext, commit: commit
        )
        if inAgent {
            request.target = ClaudeTaskRequest.agentTarget(projectPath: project.path, taskID: request.taskID)
            request.permissionMode = AgentPermissionPreferences.effectiveMode(serverID: serverID, workingDirectory: project.path)
        }
        await perform {
            try await self.service.enqueueTask(request, projectPath: self.project.path)
            self.draft = ""
        }
    }

    func cancel(_ task: ClaudeTask) async {
        await perform { try await self.service.cancelTask(task) }
    }

    func retry(_ task: ClaudeTask) async {
        await perform { try await self.service.retryTask(task) }
    }

    /// Activa el indicador de Claude (sus hooks son los que hacen avanzar la cola).
    func installHooks() async {
        await perform {
            try await self.service.installClaudeHooks()
            self.needsHooks = false
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
            errorMessage = nil
        } catch {
            Log.ssh.error("Encargos: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
        await reload()
    }
}
