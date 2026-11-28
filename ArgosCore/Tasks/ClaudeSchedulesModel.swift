//
//  ClaudeSchedulesModel.swift
//  ArgosCore
//
//  Tareas programadas de un proyecto (Mac e iPhone/iPad): listar, crear, activar o pausar,
//  ejecutar ya y borrar. Al guardar la primera, el servidor queda con el temporizador puesto.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeSchedulesModel {

    private(set) var schedules: [ClaudeSchedule] = []
    private(set) var timer: ClaudeTaskTimer.Kind?
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var notice: String?

    // Borrador de la tarea nueva.
    var title = ""
    var prompt = ""
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    var time: Date
    var push = false
    var checkCommand = ""
    var maxMinutes = 60
    var modelChoice = ClaudeTaskModelChoice.default

    /// Biblioteca de encargos del proyecto, para elegir uno.
    @ObservationIgnored let savedPrompts: [SavedPrompt]

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored private let serverID: Server.ID
    @ObservationIgnored let project: Project
    @ObservationIgnored private let calendar: Calendar

    init(
        service: any SSHServicing, serverID: Server.ID, project: Project,
        savedPrompts: [SavedPrompt] = [], calendar: Calendar = .current
    ) {
        self.savedPrompts = savedPrompts
        self.service = service
        self.serverID = serverID
        self.project = project
        self.calendar = calendar
        self.time = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date()
    }

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !weekdays.isEmpty && !isWorking
    }

    func load() async {
        do {
            let all = try await ConnectionPriority.background { try await self.service.listSchedules(projects: [self.project]) }
            schedules = all.filter { $0.projectPath == project.path }
            timer = try await ConnectionPriority.background { try await self.service.taskTimerStatus() }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Tareas programadas: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
    }

    func add() async {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let schedule = ClaudeSchedule(
            id: ClaudeSchedule.makeID(),
            title: title.trimmingCharacters(in: .whitespaces),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            projectPath: project.path,
            session: project.sessionName,
            weekdays: weekdays,
            hour: parts.hour ?? 3,
            minute: parts.minute ?? 0,
            push: push,
            checkCommand: checkCommand.trimmingCharacters(in: .whitespaces),
            maxMinutes: max(1, maxMinutes),
            permissionMode: AgentPermissionPreferences.effectiveMode(serverID: serverID, workingDirectory: project.path),
            modelChoice: modelChoice
        )
        await save(schedule) {
            self.title = ""
            self.prompt = ""
        }
    }

    /// Copia un prompt de la biblioteca. Las variables se quedan tal cual: la tarea corre
    /// más tarde y repetidas veces, y unos valores de hoy serían falsos mañana.
    /// El encargo lleva `{rama}`, `{fecha}`…: en una tarea programada no se rellenan (la
    /// interfaz lo avisa).
    var promptHasVariables: Bool { PromptVariables.containsVariables(prompt) }

    func usePrompt(_ prompt: SavedPrompt) {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = prompt.displayTitle }
        self.prompt = prompt.text
        modelChoice = modelChoice.applying(ClaudeTaskModelChoice(savedPrompt: prompt))
    }

    func setEnabled(_ schedule: ClaudeSchedule, _ enabled: Bool) async {
        var updated = schedule
        updated.enabled = enabled
        await save(updated) {}
    }

    func runNow(_ schedule: ClaudeSchedule) async {
        await perform {
            try await self.service.runScheduleNow(id: schedule.id)
            self.notice = String(localized: "«\(schedule.title)» se ha añadido a la cola de encargos.")
        }
    }

    func delete(_ schedule: ClaudeSchedule) async {
        await perform { try await self.service.deleteSchedule(id: schedule.id) }
    }

    private func save(_ schedule: ClaudeSchedule, then done: @escaping () -> Void) async {
        await perform {
            let kind = try await self.service.saveSchedule(schedule)
            self.timer = kind
            self.notice = kind == .none
                ? String(localized: "Guardada, pero el servidor no tiene launchd, systemd ni cron: no se ejecutará sola.")
                : nil
            done()
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
            Log.ssh.error("Tareas programadas: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
        await load()
    }
}
