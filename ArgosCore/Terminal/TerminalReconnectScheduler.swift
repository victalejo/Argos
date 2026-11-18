//
//  TerminalReconnectScheduler.swift
//  ArgosCore
//
//  Reintentos automáticos del terminal en vivo con `ReconnectPolicy` (la misma que
//  iPhone/iPad y Android): espera creciente, sin reintentar lo que exige una acción del
//  usuario (huella, credenciales, clave) y con el equipo dormido en pausa. Quien lo usa
//  aporta cómo reconectar (`reconnect`); aquí solo se decide CUÁNDO.
//

import Foundation
import Observation

@MainActor
@Observable
final class TerminalReconnectScheduler {
    /// Reintentos seguidos desde la última conexión buena.
    private(set) var attempt = 0
    /// Hay un reintento automático programado (el banner dice «Reconectando…»).
    private(set) var isReconnecting = false
    /// Por qué se dejó de reintentar (el banner ofrece «Reconectar»).
    private(set) var gaveUp: ReconnectPolicy.GiveUpReason?

    let policy: ReconnectPolicy
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        policy: ReconnectPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.policy = policy
        self.sleep = sleep
    }

    /// Conectó bien: se olvida la cuenta.
    func didConnect() {
        cancel()
        attempt = 0
        gaveUp = nil
    }

    /// El terminal falló con `error` (`nil` si solo se sabe el mensaje: se trata como de
    /// red). Con el equipo dormido no se programa nada (se reintenta al despertar).
    func didFail(_ error: Error?, isAsleep: Bool, reconnect: @escaping @MainActor () -> Void) {
        guard !isAsleep, pending == nil else { return }
        switch policy.decision(after: error ?? TransportFailure(), attempt: attempt) {
        case .retry(let delay):
            schedule(after: delay, reconnect: reconnect)
        case .giveUp(let reason):
            isReconnecting = false
            gaveUp = reason
        }
    }

    /// El equipo se duerme: nada programado.
    func willSleep() {
        cancel()
    }

    /// El equipo despierta: si el terminal había caído, se empieza de cero.
    func didWake(terminalFailed: Bool, lastError: Error?, reconnect: @escaping @MainActor () -> Void) {
        guard terminalFailed, pending == nil else { return }
        attempt = 0
        gaveUp = nil
        didFail(lastError, isAsleep: false, reconnect: reconnect)
    }

    /// «Reconectar» del banner: desde cero y en el acto. `reconnect` levanta antes el
    /// bloqueo de la conexión (acción explícita).
    func reconnectNow(_ reconnect: @escaping @MainActor () async -> Void) {
        cancel()
        attempt = 0
        gaveUp = nil
        pending = Task { [weak self] in
            await reconnect()
            self?.pending = nil
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        isReconnecting = false
    }

    private func schedule(after delay: Duration, reconnect: @escaping @MainActor () -> Void) {
        isReconnecting = true
        gaveUp = nil
        let sleep = self.sleep
        pending = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.attempt += 1
            self.pending = nil
            reconnect()
        }
    }

    /// Fallo del que solo se conoce el mensaje (se reintenta como uno de red).
    private struct TransportFailure: Error {}
}
