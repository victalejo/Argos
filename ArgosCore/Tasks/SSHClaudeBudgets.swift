//
//  SSHClaudeBudgets.swift
//  ArgosCore
//
//  Presupuesto por proyecto en el servidor (ver `ClaudeBudgetScript`): leer la configuración
//  y el consumo, y guardarla. Al guardar se pone al día el despachador (el que frena) y el
//  índice de uso (del que saca el consumo).
//

import Foundation

extension SSHService {

    func readProjectBudget(projectKey: String) async throws -> ClaudeBudgetReading {
        guard ClaudeBudgetBlock.isSafeKey(projectKey) else { throw HomeFileError.unsafePath(projectKey) }
        let output = try await runChecked(
            RemoteTimeout.wrap(ClaudeBudgetScript.readCommand(projectKey: projectKey)),
            failureMessage: String(localized: "No se pudo leer el presupuesto del proyecto.")
        )
        return ClaudeBudgetReading(output: output)
    }

    func saveProjectBudget(_ budget: ClaudeProjectBudget, projectKey: String) async throws {
        guard ClaudeBudgetBlock.isSafeKey(projectKey) else { throw HomeFileError.unsafePath(projectKey) }
        let failure = String(localized: "No se pudo guardar el presupuesto del proyecto.")
        if budget.isEmpty {
            _ = try await runChecked(ClaudeBudgetScript.removeCommand(projectKey: projectKey), failureMessage: failure)
            return
        }
        try await ensureTaskDispatcher()
        try await startClaudeUsageIndex()
        try await writeHomeFilePrivately(
            Data(budget.configText.utf8), to: ClaudeBudgetScript.configRelativePath(projectKey: projectKey)
        )
        // Con el tope cambiado, el bloqueo anotado ya no vale: el siguiente `tick` lo evalúa.
        _ = try await runChecked(ClaudeBudgetScript.clearBlockCommand(projectKey: projectKey), failureMessage: failure)
        _ = try await runChecked(
            RemoteTimeout.wrap(ClaudeTaskScript.dispatchCommand(["tick"])), failureMessage: failure
        )
    }
}
