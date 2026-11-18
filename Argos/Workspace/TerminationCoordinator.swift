//
//  TerminationCoordinator.swift
//  Argos
//
//  Decide qué responder a `applicationShouldTerminate` (testeable sin AppKit):
//  - Con agentes trabajando o envíos en curso pregunta, salvo cuando el sistema cierra la
//    sesión o se apaga: ahí no se bloquea el apagado con un diálogo.
//  - Responde UNA sola vez: una segunda petición mientras se cierra no lanza otro cierre.
//  - Cancelar no deja la salida a medias (se puede volver a intentar).
//

import Foundation

@MainActor
final class TerminationCoordinator {
    enum Reply: Equatable {
        case cancel
        /// Se responderá con `reply(true)` cuando acabe el cierre ordenado.
        case later
    }

    private(set) var isTerminating = false
    private let workInProgress: @MainActor () -> QuitWorkInProgress
    private let isSystemSessionEnding: @MainActor () -> Bool
    private let confirm: @MainActor (String) -> Bool
    private let shutdown: @MainActor () async -> Void
    private let reply: @MainActor (Bool) -> Void

    init(
        workInProgress: @escaping @MainActor () -> QuitWorkInProgress,
        isSystemSessionEnding: @escaping @MainActor () -> Bool,
        confirm: @escaping @MainActor (String) -> Bool,
        shutdown: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        self.workInProgress = workInProgress
        self.isSystemSessionEnding = isSystemSessionEnding
        self.confirm = confirm
        self.shutdown = shutdown
        self.reply = reply
    }

    func shouldTerminate() -> Reply {
        if isTerminating { return .later }
        if !isSystemSessionEnding(), let message = workInProgress().message, !confirm(message) {
            return .cancel
        }
        isTerminating = true
        Task { @MainActor in
            await shutdown()
            reply(true)
        }
        return .later
    }
}
