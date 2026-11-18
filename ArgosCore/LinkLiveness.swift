//
//  LinkLiveness.swift
//  ArgosCore
//
//  Cuándo dar por muerta una conexión SSH vigilada (lógica pura, testeable).
//
//  Un sondeo es un canal exec con `true`. Su resultado NO siempre dice algo de la
//  conexión:
//   - Rechazo del canal («no more sessions»): el servidor ha RESPONDIDO, está vivo. Con
//     `MaxSessions 1` el terminal ya ocupa el único canal y todos los sondeos se rechazan.
//   - Sin respuesta (plazo vencido, o Citadel se rinde abriendo el canal a los 15 s): es
//     lo que se ve con una conexión medio abierta, pero también con el servidor en swap.
//     Por eso solo se cierra tras varios seguidos.
//   - Conexión ya cerrada o cortada: muerta sin más.
//

import Foundation
@preconcurrency import Citadel
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH

/// Resultado de un sondeo.
enum ProbeOutcome: Sendable, Equatable {
    /// El comando corrió.
    case alive
    /// El servidor rechazó el canal: está vivo, solo que sin canales libres.
    case rejected
    /// No hubo respuesta a tiempo (no concluyente por sí solo).
    case unresponsive
    /// La conexión ya está cerrada o se cortó.
    case broken

    /// Clasifica el error de un sondeo fallido.
    static func from(error: Error) -> ProbeOutcome {
        if ChannelRetry.isChannelRejection(error) { return .rejected }
        if let ssh = error as? NIOSSHError,
           ssh.type == .tcpShutdown || ssh.type == .creatingChannelAfterClosure {
            return .broken
        }
        if let channel = error as? ChannelError {
            switch channel {
            case .ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed, .inputClosed: return .broken
            default: return .unresponsive
            }
        }
        if (error as? SSHConnectionError) == .notConnected { return .broken }
        return .unresponsive
    }
}

/// Fallos seguidos de una conexión vigilada (inmutable).
struct LinkLiveness: Sendable, Equatable {
    let consecutiveFailures: Int

    init(consecutiveFailures: Int = 0) {
        self.consecutiveFailures = max(0, consecutiveFailures)
    }

    func recording(_ outcome: ProbeOutcome, threshold: Int) -> LinkLiveness {
        switch outcome {
        case .alive, .rejected: return LinkLiveness()
        case .unresponsive: return LinkLiveness(consecutiveFailures: consecutiveFailures + 1)
        case .broken: return LinkLiveness(consecutiveFailures: max(threshold, consecutiveFailures + 1))
        }
    }

    func isDead(threshold: Int) -> Bool { consecutiveFailures >= max(1, threshold) }
}

/// Ritmo y tolerancia de los vigilantes. Inyectable para los tests (no esperar 30 s).
struct ConnectionMonitorPolicy: Sendable, Equatable {
    /// Latido de la compartida: intervalo, plazo y fallos seguidos para descartarla.
    let heartbeatInterval: Duration
    let heartbeatTimeout: Duration
    let sharedFailuresToDiscard: Int
    /// Vigilante de cada conexión dedicada o túnel.
    let linkInterval: Duration
    let linkTimeout: Duration
    let linkFailuresToClose: Int
    /// Tras un fallo se vuelve a mirar antes, para confirmar o descartar pronto.
    let retryInterval: Duration
    /// Canales abandonados (comandos vencidos que siguen abiertos) que fuerzan a reciclar
    /// la conexión compartida antes de agotar `MaxSessions`.
    let abandonedChannelLimit: Int

    init(
        heartbeatInterval: Duration = .seconds(30),
        heartbeatTimeout: Duration = .seconds(30),
        sharedFailuresToDiscard: Int = 2,
        linkInterval: Duration = .seconds(30),
        linkTimeout: Duration = .seconds(20),
        linkFailuresToClose: Int = 3,
        retryInterval: Duration = .seconds(5),
        abandonedChannelLimit: Int = 3
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.heartbeatTimeout = heartbeatTimeout
        self.sharedFailuresToDiscard = max(1, sharedFailuresToDiscard)
        self.linkInterval = linkInterval
        self.linkTimeout = linkTimeout
        self.linkFailuresToClose = max(1, linkFailuresToClose)
        self.retryInterval = retryInterval
        self.abandonedChannelLimit = max(1, abandonedChannelLimit)
    }

    static let standard = ConnectionMonitorPolicy()
}

/// Última vez que una conexión movió datos. Una conexión con tráfico reciente está viva:
/// no se sondea (ahorra canales y no se toma una cola lenta por una caída).
final class LinkActivity: Sendable {
    private let box = NIOLockedValueBox<ContinuousClock.Instant?>(nil)

    init() {}

    func touch(at now: ContinuousClock.Instant = .now) {
        box.withLockedValue { $0 = now }
    }

    func reset() {
        box.withLockedValue { $0 = nil }
    }

    var last: ContinuousClock.Instant? { box.withLockedValue { $0 } }

    func isRecent(within window: Duration, now: ContinuousClock.Instant = .now) -> Bool {
        guard let last else { return false }
        return now - last < window
    }
}
