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

@MainActor
@Observable
final class TerminalSessionStore {
    /// Controladores vivos por sesión. Persisten hasta `close`/`closeAll`.
    private var controllers: [SessionHandle: LiveTerminalController] = [:]

    /// Handles ordenados por uso, de MENOS a MÁS reciente (el último es el actual). Se usa
    /// para desalojar (LRU) cuando el pool supera `maxLive`.
    private var lruOrder: [SessionHandle] = []

    /// Tope de terminales vivos a la vez (ajustable en Ajustes → Terminal). Se consulta
    /// en cada apertura; inyectable para tests. Al superarlo se desengancha (detach) el
    /// menos usado, que vuelve a "dormido" y se reconecta al reabrirlo.
    private let maxLive: @MainActor () -> Int

    init(maxLive: @escaping @MainActor () -> Int = { TerminalSettings.shared.maxLiveTerminals }) {
        self.maxLive = maxLive
    }

    /// Devuelve el controlador de `handle`, creándolo (y conectándolo) si no existe.
    /// Reutilizar el existente es lo que hace la conexión persistente.
    func controller(
        for handle: SessionHandle,
        service: any SSHServicing,
        sessionName: String
    ) -> LiveTerminalController {
        touch(handle)
        if let existing = controllers[handle] { return existing }
        let controller = LiveTerminalController(service: service, sessionName: sessionName)
        controllers[handle] = controller
        evictIfNeeded(keeping: handle)
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
        lruOrder.removeAll { $0 == handle }
    }

    // MARK: - LRU

    /// Marca `handle` como el más recientemente usado.
    private func touch(_ handle: SessionHandle) {
        lruOrder.removeAll { $0 == handle }
        lruOrder.append(handle)
    }

    /// Desengancha los terminales menos usados hasta respetar `maxLive`,
    /// nunca el recién solicitado (`keep`).
    private func evictIfNeeded(keeping keep: SessionHandle) {
        let victims = Self.evictionVictims(
            lruOrder: lruOrder,
            keep: keep,
            maxLive: maxLive()
        )
        for victim in victims {
            Log.terminal.notice("Pool de terminales lleno: se desengancha la sesión menos usada.")
            close(victim)
        }
    }

    /// Lógica pura (testeable) de selección de víctimas LRU: si `lruOrder` (de menos a más
    /// reciente) supera `maxLive`, devuelve los más antiguos a desalojar, excluyendo `keep`.
    static func evictionVictims(
        lruOrder: [SessionHandle],
        keep: SessionHandle,
        maxLive: Int
    ) -> [SessionHandle] {
        guard lruOrder.count > maxLive else { return [] }
        let overflow = lruOrder.count - maxLive
        var victims: [SessionHandle] = []
        for handle in lruOrder where handle != keep {
            victims.append(handle)
            if victims.count == overflow { break }
        }
        return victims
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

// MARK: - Estado para el filtro de proyectos

extension TerminalSessionStore {
    /// Estado de un proyecto del servidor `serverID` para el filtro.
    func status(of entry: ProjectEntry, serverID: Server.ID) -> ProjectStatus {
        let handle = SessionHandle(serverID: serverID, sessionID: entry.project.sessionName)
        let connection = entry.session.map { connectionState(for: handle, isAttached: $0.isAttached) }
        return .of(connection: connection, onMac: entry.project.macCheckout != nil)
    }

    /// Estado de una sesión suelta (siempre corre; nunca está en el Mac).
    func status(of session: TmuxSession, serverID: Server.ID) -> ProjectStatus {
        let handle = SessionHandle(serverID: serverID, sessionID: session.name)
        return .of(connection: connectionState(for: handle, isAttached: session.isAttached), onMac: false)
    }
}
