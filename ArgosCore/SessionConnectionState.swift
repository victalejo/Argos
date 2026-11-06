//
//  SessionConnectionState.swift
//  ArgosCore
//
//  Estados de conexión del terminal en vivo y su mapeo al indicador visual (lógica pura).
//

import Foundation

/// Estado observable de la conexión del terminal en vivo.
enum LiveTerminalStatus: Sendable, Equatable {
    case connecting
    case connected
    case ended
    case failed(String)
}

/// Estado de conexión de una sesión, para el indicador de la lista.
enum SessionConnectionState: Equatable {
    case live              // 🟢 cargada y conectada por nosotros
    case connecting        // 🟡 estableciendo la conexión
    case error             // 🔴 falló la conexión
    case attachedElsewhere // 🔵 tmux la reporta adjunta, pero no por esta app
    case dormant           // 🌙 no cargada (nunca abierta o desconectada)

    /// Mapeo puro (testeable): estado del terminal local + flag de tmux → estado visual.
    /// `status == nil` significa que no hay terminal cargado para la sesión.
    static func from(status: LiveTerminalStatus?, isAttached: Bool) -> SessionConnectionState {
        switch status {
        case .connecting: return .connecting
        case .connected: return .live
        case .failed: return .error
        case .ended, .none: return isAttached ? .attachedElsewhere : .dormant
        }
    }
}
