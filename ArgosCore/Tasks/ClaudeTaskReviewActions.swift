//
//  ClaudeTaskReviewActions.swift
//  ArgosCore
//
//  Las dos salidas de un encargo que bloqueó el revisor automático, compartidas por la
//  pantalla «Encargos» (Mac e iPhone/iPad) y la bandeja «Te necesita» del Mac:
//  «Subir igualmente» y «Pedir a Claude que lo arregle».
//

import Foundation

enum ClaudeTaskReviewError: LocalizedError, Equatable {
    /// Al encargo le falta su carpeta, rama o ventana: no se sabe dónde arreglarlo.
    case cannotFix
    /// Ya no está bloqueado (otro dispositivo lo resolvió, o se canceló).
    case notBlocked

    var errorDescription: String? {
        switch self {
        case .cannotFix:
            return String(localized: "No se sabe dónde arreglar este encargo (falta su carpeta o su ventana). Ábrelo en «Encargos».")
        case .notBlocked:
            return String(localized: "Ese encargo ya no está bloqueado por el revisor.")
        }
    }
}

enum ClaudeTaskReviewActions {

    static func pushAnyway(_ task: ClaudeTask, service: any SSHServicing) async throws {
        guard task.isBlockedByReview else { throw ClaudeTaskReviewError.notBlocked }
        try await service.pushTaskAnyway(task)
    }

    /// Encola el arreglo en el mismo agente/rama (o ventana) con el informe como prompt.
    /// El modo de permisos del agente es el de Ajustes para ese proyecto, como al encolar.
    static func requestFix(
        _ task: ClaudeTask,
        projectPath: String,
        serverID: Server.ID,
        service: any SSHServicing
    ) async throws {
        guard task.isBlockedByReview else { throw ClaudeTaskReviewError.notBlocked }
        let mode = AgentPermissionPreferences.effectiveMode(serverID: serverID, workingDirectory: projectPath)
        guard let request = ClaudeTaskReviewFix.request(for: task, permissionMode: mode) else {
            throw ClaudeTaskReviewError.cannotFix
        }
        try await service.enqueueTask(request, projectPath: projectPath)
    }

    /// El encargo completo de un bloqueo del sondeo (la bandeja solo trae su id).
    static func task(for block: ClaudeTaskReviewBlock, service: any SSHServicing) async throws -> ClaudeTask {
        let tasks = try await service.listTasks()
        guard let task = tasks.first(where: { $0.id == block.id }), task.isBlockedByReview else {
            throw ClaudeTaskReviewError.notBlocked
        }
        return task
    }
}
