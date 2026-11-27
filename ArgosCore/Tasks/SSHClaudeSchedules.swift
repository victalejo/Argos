//
//  SSHClaudeSchedules.swift
//  ArgosCore
//
//  Tareas programadas en el servidor: guardar sus plantillas (por SFTP), listarlas,
//  borrarlas, ejecutarlas ya y poner el temporizador que llama al despachador cada minuto.
//

import Foundation

extension SSHService {

    /// Guarda (o actualiza) la tarea programada y deja el temporizador puesto. Devuelve cuál.
    @discardableResult
    func saveSchedule(_ schedule: ClaudeSchedule) async throws -> ClaudeTaskTimer.Kind {
        try await ensureTaskDispatcher()
        guard let claudePath = try await locateClaude() else { throw PersistentAgentError.claudeMissing }
        let files = try ClaudeScheduleScripts.make(schedule, claudePath: claudePath)
        let dir = "\(ClaudeScheduleScripts.directoryRelativePath)/\(schedule.id)"
        for (name, content) in [
            ("prompt", files.prompt), ("launch.tpl", files.launch), ("meta.tpl", files.meta),
            ("send.tpl", files.send), ("stop.tpl", files.stop), ("task.tpl", files.task),
            // La configuración, la última: con ella el despachador ya la tiene en cuenta.
            ("config", files.config),
        ] {
            try await writeHomeFilePrivately(Data(content.utf8), to: "\(dir)/\(name)")
        }
        return try await installTaskTimer()
    }

    func listSchedules(projects: [Project]) async throws -> [ClaudeSchedule] {
        let output = try await runChecked(
            RemoteTimeout.wrap(ClaudeScheduleScripts.listCommand),
            failureMessage: String(localized: "No se pudieron leer las tareas programadas.")
        )
        return ClaudeScheduleScripts.parse(listOutput: output, projects: projects)
    }

    func deleteSchedule(id: String) async throws {
        _ = try await runChecked(
            ClaudeScheduleScripts.deleteCommand(id: id),
            failureMessage: String(localized: "No se pudo borrar la tarea programada.")
        )
    }

    func runScheduleNow(id: String) async throws {
        try await ensureTaskDispatcher()
        _ = try await runChecked(
            RemoteTimeout.wrap(ClaudeTaskScript.dispatchCommand(["run", id])),
            failureMessage: String(localized: "No se pudo lanzar la tarea programada.")
        )
    }

    func installTaskTimer() async throws -> ClaudeTaskTimer.Kind {
        let output = try await runChecked(
            ClaudeTaskTimer.installCommand,
            failureMessage: String(localized: "No se pudo poner el temporizador de las tareas programadas.")
        )
        return ClaudeTaskTimer.parse(output)
    }

    func taskTimerStatus() async throws -> ClaudeTaskTimer.Kind {
        ClaudeTaskTimer.parse(try await runChecked(
            ClaudeTaskTimer.statusCommand,
            failureMessage: String(localized: "No se pudo comprobar el temporizador.")
        ))
    }
}
