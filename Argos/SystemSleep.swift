//
//  SystemSleep.swift
//  Argos
//
//  Pausa el tráfico SSH proactivo mientras el Mac duerme: el heartbeat de
//  `SSHService`, el sondeo de ventanas y la reconexión automática del terminal no
//  deben abrir conexiones con la tapa cerrada. Al despertar se comprueba la conexión
//  de inmediato y, si el terminal cayó, se reconecta solo.
//
//  Basado en la PR #2 de Kevin Jovy (@AloreBB), que detectó el problema y propuso
//  `SuspensionMonitor`. Aquí se limita la pausa al reposo del sistema (no a cambiar
//  de app, donde el keep-alive es justo lo que evita el «terminal congelado»).
//

import AppKit
import Foundation
import Observation

// MARK: - Monitor de reposo

/// Observa `NSWorkspace.willSleepNotification` / `didWakeNotification` y expone
/// `isAsleep` para SwiftUI. El centro de notificaciones es inyectable para tests.
@MainActor
@Observable
final class SystemSleepMonitor {
    static let shared = SystemSleepMonitor()

    /// `true` entre `willSleep` y `didWake`.
    private(set) var isAsleep = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = true }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isAsleep = false }
            },
        ]
    }
}

// MARK: - Aplicación ordenada a los servicios

/// Aplica suspender/reanudar el heartbeat a todos los servicios EN ORDEN: cada cambio
/// espera al anterior, así un reposo muy breve (dormir → despertar seguidos) nunca deja
/// el keep-alive pausado con el Mac despierto.
@MainActor
final class HeartbeatSleepCoordinator {
    private var last: Task<Void, Never>?

    @discardableResult
    func apply(asleep: Bool, to services: [any SSHServicing]) -> Task<Void, Never> {
        let previous = last
        let task = Task {
            await previous?.value
            for service in services {
                if asleep {
                    await service.suspendHeartbeat()
                } else {
                    await service.resumeHeartbeat()
                }
            }
        }
        last = task
        return task
    }
}

// MARK: - Política del terminal (pura, testeable)

enum TerminalSleepPolicy {
    /// Al despertar, solo se reintenta un terminal que cayó por error de red/SSH; el
    /// detach limpio (`.ended`) no se reconecta solo.
    static func reconnectsOnWake(_ status: LiveTerminalStatus?) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
