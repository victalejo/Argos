//
//  ChannelGate.swift
//  Argos
//
//  Tope de canales SSH simultáneos sobre la conexión compartida. OpenSSH admite
//  `MaxSessions` (10 por defecto) canales de sesión por conexión; los comandos cortos
//  (sondeos de Claude, git, puertos…) y las transferencias en paralelo podían coincidir y
//  pasar de ese límite, y el servidor rechazaba el canal («no more sessions» →
//  `NIOSSHError.channelSetupRejected`). Quien llega con el cupo lleno espera su turno.
//
//  - Dos clases de turno: el usuario tiene preferencia y el fondo, un cupo menor
//    (`backgroundLimit`), para que una acción no espere detrás de los sondeos.
//  - Esperar es cancelable: una tarea cancelada sale de la cola sin ocupar turno.
//  - Límite adaptativo: si el servidor rechaza un canal, el tope baja para esa conexión
//    (`lowerLimitAfterRejection`) y vuelve al de partida con la siguiente (`resetLimit`).
//  - El latido NO pasa por aquí: tiene su propio canal reservado fuera del cupo.
//

import Foundation
import NIOSSH

actor ChannelGate {
    /// Canales a la vez: deja margen bajo `MaxSessions` para el SFTP persistente y el latido.
    static let sharedConnectionLimit = 6

    /// Tope de partida (el adaptativo nunca lo supera).
    nonisolated let limit: Int
    /// Tope vigente para la conexión actual.
    private(set) var currentLimit: Int
    private var inUse: [ConnectionPriority: Int] = [:]
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let priority: ConnectionPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    init(limit: Int = ChannelGate.sharedConnectionLimit) {
        self.limit = max(1, limit)
        self.currentLimit = max(1, limit)
    }

    var activeCount: Int { inUse.values.reduce(0, +) }
    var waitingCount: Int { waiters.count }
    /// Canales que puede ocupar a la vez el trabajo de fondo (la mitad del tope).
    var backgroundLimit: Int { max(1, currentLimit / 2) }

    func activeCount(_ priority: ConnectionPriority) -> Int { inUse[priority, default: 0] }

    /// Espera turno. Lanza `CancellationError` si la tarea se cancela mientras espera
    /// (y entonces NO ocupa turno).
    func acquire(_ priority: ConnectionPriority = .user) async throws {
        try Task.checkCancellation()
        if canAdmit(priority) {
            admit(priority)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            // Corre fuera del actor: la retirada se hace dentro. Llega siempre después de
            // encolarse (el actor no la atiende hasta que `acquire` queda suspendido).
            Task { await self.cancelWaiter(id) }
        }
    }

    func release(_ priority: ConnectionPriority = .user) {
        inUse[priority] = max(0, inUse[priority, default: 0] - 1)
        dispatch()
    }

    /// El servidor rechazó un canal con `activeCount` abiertos (contando el rechazado):
    /// el tope baja a uno menos y se recuerda para esta conexión. Devuelve el nuevo tope.
    @discardableResult
    func lowerLimitAfterRejection() -> Int {
        let floor = min(limit, Self.minimumAdaptiveLimit)
        let candidate = max(floor, min(currentLimit, activeCount) - 1)
        if candidate < currentLimit { currentLimit = candidate }
        return currentLimit
    }

    /// Conexión nueva: se vuelve al tope de partida.
    func resetLimit() {
        currentLimit = limit
        dispatch()
    }

    /// Nunca se baja de aquí: con menos, la app entera iría a paso de tortuga.
    private static let minimumAdaptiveLimit = 2

    // MARK: - Reparto

    private func canAdmit(_ priority: ConnectionPriority) -> Bool {
        guard activeCount < currentLimit else { return false }
        return priority == .user || activeCount(.background) < backgroundLimit
    }

    private func admit(_ priority: ConnectionPriority) {
        inUse[priority, default: 0] += 1
    }

    /// Entrega turnos libres: primero al usuario (en orden de llegada), luego al fondo.
    private func dispatch() {
        while let index = nextEligibleWaiter() {
            let waiter = waiters.remove(at: index)
            admit(waiter.priority)
            waiter.continuation.resume()
        }
    }

    private func nextEligibleWaiter() -> Int? {
        if let user = waiters.firstIndex(where: { $0.priority == .user }), canAdmit(.user) {
            return user
        }
        guard canAdmit(.background) else { return nil }
        return waiters.firstIndex { $0.priority == .background }
    }

    private func cancelWaiter(_ id: UUID) {
        // Si ya no está en la cola es que recibió turno: lo libera quien lo pidió.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// ¿Rechazó el servidor abrir el canal? Entonces el comando NUNCA llegó a ejecutarse
/// y reintentarlo es seguro.
enum ChannelRetry {
    static let maxAttempts = 4

    /// El servidor no admitió el canal («no more sessions»).
    static func isChannelRejection(_ error: Error) -> Bool {
        (error as? NIOSSHError)?.type == .channelSetupRejected
    }

    /// Espera antes del reintento `attempt` (1, 2, 3…): crece para dar tiempo a que se
    /// cierren canales.
    static func delay(forAttempt attempt: Int) -> Duration {
        .milliseconds(300 * attempt)
    }
}
