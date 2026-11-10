//
//  PortForwardIdlePolicy.swift
//  ArgosCore
//
//  Cierre automático de túneles sin uso (lógica pura + preferencia del dispositivo).
//  «Sin uso» = ninguna conexión abierta por el túnel durante el límite: una web con recarga
//  en caliente conectada (websocket) lo mantiene vivo.
//

import Foundation
import NIOConcurrencyHelpers

enum PortForwardIdlePolicy {

    /// Opciones del selector, en minutos (0 = nunca).
    static let options: [Int] = [0, 5, 15, 30, 60]
    static let defaultMinutes = 15
    static let defaultsKey = "portForwardIdleMinutes"

    /// Límite elegido en este dispositivo (UserDefaults; se lee en cada comprobación).
    static var limitMinutes: Int {
        get {
            guard let value = UserDefaults.standard.object(forKey: defaultsKey) as? Int,
                  options.contains(value) else { return defaultMinutes }
            return value
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// ¿Hay que cerrar el túnel? Nunca con conexiones abiertas ni con el límite en 0.
    static func shouldClose(activeConnections: Int, lastActivity: Date, now: Date, limitMinutes: Int) -> Bool {
        guard limitMinutes > 0, activeConnections == 0 else { return false }
        return now.timeIntervalSince(lastActivity) >= TimeInterval(limitMinutes * 60)
    }

    /// Texto del selector.
    static func label(minutes: Int) -> String {
        minutes == 0 ? "Nunca" : "\(minutes) min"
    }
}

/// Conexiones abiertas y última actividad de un túnel. La actualiza el event loop de NIO
/// (al aceptar y al cerrar cada conexión) y la lee el actor: por eso va con candado.
final class PortForwardActivity: Sendable {
    private struct State {
        var active = 0
        var lastActivity: Date
    }

    private let box: NIOLockedValueBox<State>

    init(now: Date = Date()) {
        box = NIOLockedValueBox(State(lastActivity: now))
    }

    func connectionOpened(now: Date = Date()) {
        box.withLockedValue { $0.active += 1; $0.lastActivity = now }
    }

    func connectionClosed(now: Date = Date()) {
        box.withLockedValue { $0.active = max(0, $0.active - 1); $0.lastActivity = now }
    }

    var snapshot: (active: Int, lastActivity: Date) {
        box.withLockedValue { ($0.active, $0.lastActivity) }
    }
}
