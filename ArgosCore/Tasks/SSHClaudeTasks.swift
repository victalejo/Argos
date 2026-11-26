//
//  SSHClaudeTasks.swift
//  ArgosCore
//
//  Cola de encargos en el servidor: instalar el despachador, encolar (el prompt viaja por
//  SFTP, nunca en la línea de comandos), listar, cancelar y reintentar.
//

import Foundation

extension SSHService {

    /// Pone el despachador al día (si cambió) y los hooks del indicador en su versión
    /// actual, que son los que avisan al despachador.
    func ensureTaskDispatcher() async throws {
        let installed = try await readHomeFile(ClaudeTaskScript.scriptRelativePath)
        if installed != ClaudeTaskScript.script {
            try await writeHomeFilePrivately(Data(ClaudeTaskScript.script.utf8), to: ClaudeTaskScript.scriptRelativePath)
        }
        try await upgradeClaudeHooksIfOutdated()
    }

    func enqueueTask(_ request: ClaudeTaskRequest, projectPath: String) async throws {
        try await ensureTaskDispatcher()
        let id = ClaudeTaskRequest.makeID()
        let key = ClaudeUsageProjects.key(forPath: projectPath)
        let incoming = ClaudeTaskScript.incomingRelativePath
        try await writeHomeFilePrivately(Data(request.prompt.utf8), to: "\(incoming)/\(id).prompt")
        try await writeHomeFilePrivately(Data(request.metaText(directory: projectPath).utf8), to: "\(incoming)/\(id).meta")
        _ = try await runChecked(
            RemoteTimeout.wrap(ClaudeTaskScript.dispatchCommand(["enqueue", key, id])),
            failureMessage: String(localized: "No se pudo añadir el encargo a la cola.")
        )
    }

    func listTasks() async throws -> [ClaudeTask] {
        let output = try await runChecked(
            RemoteTimeout.wrap(ClaudeTaskScript.listCommand),
            failureMessage: String(localized: "No se pudo leer la cola de encargos.")
        )
        return ClaudeTask.parse(listOutput: output)
    }

    func cancelTask(_ task: ClaudeTask) async throws {
        try await taskAction("cancel", task)
    }

    func retryTask(_ task: ClaudeTask) async throws {
        try await ensureTaskDispatcher()
        try await taskAction("retry", task)
    }

    private func taskAction(_ action: String, _ task: ClaudeTask) async throws {
        _ = try await runChecked(
            RemoteTimeout.wrap(ClaudeTaskScript.dispatchCommand([action, task.projectKey, task.folder])),
            failureMessage: String(localized: "No se pudo cambiar el encargo.")
        )
    }
}
