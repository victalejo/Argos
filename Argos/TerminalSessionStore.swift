//
//  TerminalSessionStore.swift
//  Argos
//
//  Pool de terminales en vivo (`LiveTerminalController`) indexado por `SessionHandle`.
//  Mantiene las conexiones VIVAS aunque cambies de sesión seleccionada: volver a una
//  sesión ya abierta es instantáneo (no se re-attacha). De aquí también sale el estado
//  visual de cada sesión (el puntito de color).
//

import Observation

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

@MainActor
@Observable
final class TerminalSessionStore {
    /// Controladores vivos por sesión. Persisten hasta `close`/`closeAll`.
    private var controllers: [SessionHandle: LiveTerminalController] = [:]

    /// Devuelve el controlador de `handle`, creándolo (y conectándolo) si no existe.
    /// Reutilizar el existente es lo que hace la conexión persistente.
    func controller(
        for handle: SessionHandle,
        service: any SSHServicing,
        sessionName: String
    ) -> LiveTerminalController {
        if let existing = controllers[handle] { return existing }
        let controller = LiveTerminalController(service: service, sessionName: sessionName)
        controllers[handle] = controller
        return controller
    }

    func existingController(for handle: SessionHandle) -> LiveTerminalController? {
        controllers[handle]
    }

    /// Estado visual de una sesión combinando el controlador (si hay) y el flag de
    /// tmux (`isAttached`, que indica si ALGÚN cliente está adjunto).
    func connectionState(for handle: SessionHandle, isAttached: Bool) -> SessionConnectionState {
        SessionConnectionState.from(status: controllers[handle]?.status, isAttached: isAttached)
    }

    /// Desconecta (detach) y olvida el controlador: la sesión pasa a dormida.
    func close(_ handle: SessionHandle) {
        controllers[handle]?.stop()
        controllers.removeValue(forKey: handle)
    }

    /// Cierra todos los terminales de un servidor (al eliminarlo/editarlo).
    func closeAll(forServer serverID: Server.ID) {
        for handle in controllers.keys where handle.serverID == serverID {
            close(handle)
        }
    }

    /// Fuerza una reconexión limpia (cierra y recrea).
    @discardableResult
    func reconnect(
        _ handle: SessionHandle,
        service: any SSHServicing,
        sessionName: String
    ) -> LiveTerminalController {
        close(handle)
        return controller(for: handle, service: service, sessionName: sessionName)
    }
}
