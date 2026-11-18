//
//  AgentSessionStore.swift
//  Argos
//
//  Pool de agentes de Claude Code por proyecto/sesión (`SessionHandle`), con VARIAS
//  conversaciones en pestañas por cada uno (como las ventanas del terminal). Mantiene
//  los agentes vivos aunque cambies de proyecto o de pestaña (Terminal/Archivos/Agente).
//
//  Hay dos clases de pestaña (`AgentTabSlot`): conversaciones «de esta sesión» (su
//  `claude` vive con la conexión) y agentes PERSISTENTES del servidor (creados aquí, en el
//  iPhone/iPad, Android u otro Mac), a los que la pestaña solo se engancha.
//
//  Al llegar al tope NO cierra nada por su cuenta: la vista pregunta cuál cerrar. Las
//  conversaciones cerradas se recuerdan para reanudarlas (`--resume`). Al salir de la app
//  `stopAll()` mata los `claude` de esta sesión y solo DESENGANCHA los persistentes; al
//  conectar, `cleanUpOrphans` mata los del panel que este dispositivo lanzó y ya no tienen
//  pestaña viva (nunca un persistente). Ver `AgentSessionStore+Persistent.swift`.
//

import Foundation
import Observation

/// Una conversación del panel de agente.
struct AgentTab: Identifiable {
    let id: UUID
    /// Número visible ("Conversación 2"), creciente por proyecto.
    let number: Int
    let session: ClaudeAgentSession
    /// Modo con el que arrancó: puede diferir del que el selector aplica a las nuevas.
    let permissionMode: ClaudeAgentCommand.PermissionMode

    /// Título: el inicio del primer mensaje del usuario, o "Conversación N".
    @MainActor var title: String {
        AgentTab.title(items: session.state.items) ?? String(localized: "Conversación \(number)")
    }

    static func title(items: [AgentTranscriptItem]) -> String? {
        for item in items {
            if case .userText(let text) = item.kind {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                return line.count > 28 ? String(line.prefix(27)) + "…" : line
            }
        }
        return nil
    }
}

/// Pestaña de un agente persistente (la pestaña solo se engancha a su log).
struct PersistentAgentTab: Identifiable {
    let id: UUID
    let number: Int
    let session: PersistentAgentSession

    /// El inicio del primer mensaje del usuario, o el título con el que se creó.
    @MainActor var title: String {
        AgentTab.title(items: session.state.items) ?? session.meta.title
    }
}

/// Una pestaña del panel: conversación de esta sesión o agente persistente.
enum AgentTabSlot: Identifiable {
    case session(AgentTab)
    case persistent(PersistentAgentTab)

    var id: UUID {
        switch self {
        case .session(let tab): return tab.id
        case .persistent(let tab): return tab.id
        }
    }

    var number: Int {
        switch self {
        case .session(let tab): return tab.number
        case .persistent(let tab): return tab.number
        }
    }

    var lifecycle: AgentConversationLifecycle {
        switch self {
        case .session: return .session
        case .persistent: return .persistent
        }
    }

    @MainActor var title: String {
        switch self {
        case .session(let tab): return tab.title
        case .persistent(let tab): return tab.title
        }
    }

    @MainActor var conversation: any AgentConversationDriving {
        switch self {
        case .session(let tab): return tab.session
        case .persistent(let tab): return tab.session
        }
    }

    @MainActor var permissionMode: ClaudeAgentCommand.PermissionMode {
        switch self {
        case .session(let tab): return tab.permissionMode
        case .persistent(let tab): return tab.session.meta.resolvedPermissionMode
        }
    }

    var sessionTab: AgentTab? {
        if case .session(let tab) = self { return tab }
        return nil
    }

    var persistentTab: PersistentAgentTab? {
        if case .persistent(let tab) = self { return tab }
        return nil
    }
}

/// Una pestaña con el proyecto al que pertenece.
struct AgentTabEntry: Identifiable {
    let handle: SessionHandle
    let tab: AgentTab
    var id: UUID { tab.id }
}

/// Una conversación cerrada que se puede reanudar con `--resume`.
struct ClosedAgentConversation: Identifiable, Equatable, Sendable {
    let sessionID: String
    let title: String
    let workingDirectory: String
    let permissionMode: ClaudeAgentCommand.PermissionMode
    let state: AgentConversationState
    let closedAt: Date

    var id: String { sessionID }
}

/// ¿Cabe otra conversación? (lógica pura)
enum AgentTabCapacity: Equatable {
    case available
    /// Tope alcanzado: hay que elegir cuál cerrar (no se desaloja en silencio).
    case full(limit: Int)

    static func decide(running: Int, limit: Int) -> AgentTabCapacity {
        running < limit ? .available : .full(limit: limit)
    }
}

@MainActor
@Observable
final class AgentSessionStore {

    /// Pestañas de cada proyecto, en orden. (Interno para la extensión de persistentes.)
    var slotsByHandle: [SessionHandle: [AgentTabSlot]] = [:]
    var selectedByHandle: [SessionHandle: UUID] = [:]
    var counters: [SessionHandle: Int] = [:]
    var closedByHandle: [SessionHandle: [ClosedAgentConversation]] = [:]
    /// Agentes persistentes de los servidores conectados (lista «En el servidor» y bandeja).
    let watch = PersistentAgentWatch()
    /// Comprobaciones de Claude ya hechas por servidor: al cambiar de proyecto se muestran
    /// las pestañas al instante y se verifica en segundo plano.
    var readinessCache: [Server.ID: AgentServerReadiness] = [:]
    @ObservationIgnored private var lastCleanup: [Server.ID: Date] = [:]
    @ObservationIgnored private var resuming: Set<UUID> = []
    /// Pestañas que se están pasando al servidor.
    @ObservationIgnored var converting: Set<UUID> = []
    @ObservationIgnored let registry: AgentPanelRegistry

    /// Tope de agentes vivos a la vez EN TOTAL (cada uno es un `claude` remoto que ocupa
    /// ~0,5 GB en el servidor).
    static let maxLiveSessions = AgentLaunchGuard.maxLiveAgents
    /// Conversaciones cerradas que se recuerdan por proyecto.
    static let maxClosedConversations = 10
    /// Entre dos limpiezas de huérfanos del mismo servidor.
    static let cleanupInterval: TimeInterval = 120

    init(registry: AgentPanelRegistry = AgentPanelRegistry()) {
        self.registry = registry
        watch.viewing = { [weak self] in self?.viewingPersistent ?? [:] }
    }

    /// Conversaciones de esta sesión de un proyecto.
    func tabs(for handle: SessionHandle) -> [AgentTab] {
        slots(for: handle).compactMap(\.sessionTab)
    }

    /// Todas las pestañas de un proyecto (de esta sesión y persistentes), en orden.
    func slots(for handle: SessionHandle) -> [AgentTabSlot] {
        slotsByHandle[handle] ?? []
    }

    func selectedSlot(for handle: SessionHandle) -> AgentTabSlot? {
        let slots = slots(for: handle)
        return slots.first { $0.id == selectedByHandle[handle] } ?? slots.last
    }

    func select(_ tabID: UUID, for handle: SessionHandle) {
        selectedByHandle[handle] = tabID
    }

    /// Todas las conversaciones DE ESTA SESIÓN con su proyecto (para elegir cuál cerrar al
    /// llegar al tope, avisar al salir y saber si una conexión nueva cortaría algo). Los
    /// persistentes no cuentan: no dependen de esta app.
    var allTabs: [AgentTabEntry] {
        slotsByHandle.flatMap { handle, slots in
            slots.compactMap(\.sessionTab).map { AgentTabEntry(handle: handle, tab: $0) }
        }
    }

    /// Conversaciones con su `claude` en marcha.
    var liveCount: Int { allTabs.filter { $0.tab.session.isRunning }.count }

    var capacity: AgentTabCapacity {
        AgentTabCapacity.decide(running: liveCount, limit: Self.maxLiveSessions)
    }

    /// Abre una conversación nueva (pestaña) y la selecciona. Comprueba `capacity` antes:
    /// el store ya no cierra conversaciones por su cuenta.
    @discardableResult
    func newTab(
        for handle: SessionHandle,
        service: any SSHServicing,
        command: String,
        workingDirectory: String,
        oauthToken: String?,
        permissionMode: ClaudeAgentCommand.PermissionMode,
        sessionID: String = UUID().uuidString.lowercased(),
        initialState: AgentConversationState = AgentConversationState()
    ) -> AgentTab {
        let tab = AgentTab(
            id: UUID(),
            number: nextNumber(for: handle),
            session: ClaudeAgentSession(
                service: service, command: command, workingDirectory: workingDirectory,
                oauthToken: oauthToken, sessionID: sessionID, initialState: initialState
            ),
            permissionMode: permissionMode
        )
        registry.record(sessionID, serverID: handle.serverID)
        slotsByHandle[handle, default: []].append(.session(tab))
        selectedByHandle[handle] = tab.id
        return tab
    }

    /// Número para una pestaña nueva del proyecto.
    func nextNumber(for handle: SessionHandle) -> Int {
        let number = (counters[handle] ?? 0) + 1
        counters[handle] = number
        return number
    }

    /// Reanuda en la MISMA pestaña una conversación terminada (`--resume`), conservando lo
    /// que ya se veía. `command` debe ser `ClaudeAgentCommand.build(…, resume: true)`.
    /// Antes mata y ESPERA al claude anterior con ese id (tras un corte de SSH puede seguir
    /// vivo): nunca dos procesos sobre la misma conversación.
    func resumeTab(_ tabID: UUID, for handle: SessionHandle, service: any SSHServicing, command: String, oauthToken: String?) async {
        guard let old = tabs(for: handle).first(where: { $0.id == tabID }), !old.session.isRunning,
              !resuming.contains(tabID) else { return }
        resuming.insert(tabID)
        defer { resuming.remove(tabID) }
        await old.session.stopAndWait()
        guard var slots = slotsByHandle[handle], let index = slots.firstIndex(where: { $0.id == tabID }),
              slots[index].sessionTab?.session === old.session else { return }
        let session = ClaudeAgentSession(
            service: service, command: command, workingDirectory: old.session.workingDirectory,
            oauthToken: oauthToken, sessionID: old.session.sessionID, initialState: old.session.state
        )
        slots[index] = .session(AgentTab(id: old.id, number: old.number, session: session, permissionMode: old.permissionMode))
        slotsByHandle[handle] = slots
        registry.record(old.session.sessionID, serverID: handle.serverID)
    }

    /// Reabre una conversación cerrada en una pestaña nueva (`--resume`), tras asegurarse
    /// de que no queda ningún claude anterior con ese id.
    @discardableResult
    func reopen(
        _ closed: ClosedAgentConversation,
        for handle: SessionHandle,
        service: any SSHServicing,
        command: String,
        oauthToken: String?
    ) async -> AgentTab {
        closedByHandle[handle]?.removeAll { $0.sessionID == closed.sessionID }
        do {
            _ = try await service.runAgentScript(ServerAgentInventory.stopPanelSessions([closed.sessionID]))
        } catch {
            Log.agent.error("No se pudo comprobar el claude anterior: \(error.localizedDescription, privacy: .private)")
        }
        return newTab(
            for: handle, service: service, command: command, workingDirectory: closed.workingDirectory,
            oauthToken: oauthToken, permissionMode: closed.permissionMode,
            sessionID: closed.sessionID, initialState: closed.state
        )
    }

    func closedConversations(for handle: SessionHandle) -> [ClosedAgentConversation] {
        closedByHandle[handle] ?? []
    }

    /// Cierra una pestaña. Una conversación de esta sesión se DETIENE (mata su `claude`
    /// remoto) y, si tenía mensajes, se recuerda para reanudarla. Un agente persistente solo
    /// se desengancha: sigue en el servidor (ver `AgentTabClosePolicy`).
    func closeTab(_ tabID: UUID, for handle: SessionHandle) {
        guard var slots = slotsByHandle[handle], let index = slots.firstIndex(where: { $0.id == tabID }) else { return }
        switch slots[index] {
        case .session(let tab):
            tab.session.stop()
            remember(tab, for: handle)
        case .persistent(let tab):
            tab.session.detach()
        }
        slots.remove(at: index)
        slotsByHandle[handle] = slots.isEmpty ? nil : slots
        if selectedByHandle[handle] == tabID {
            selectedByHandle[handle] = slots.indices.contains(index) ? slots[index].id : slots.last?.id
        }
    }

    private func remember(_ tab: AgentTab, for handle: SessionHandle) {
        guard tab.session.hasConversation, !tab.session.sessionID.isEmpty else { return }
        let closed = ClosedAgentConversation(
            sessionID: tab.session.sessionID,
            title: tab.title,
            workingDirectory: tab.session.workingDirectory,
            permissionMode: tab.permissionMode,
            state: tab.session.state,
            closedAt: Date()
        )
        var list = (closedByHandle[handle] ?? []).filter { $0.sessionID != closed.sessionID }
        list.insert(closed, at: 0)
        closedByHandle[handle] = Array(list.prefix(Self.maxClosedConversations))
    }

    /// Cierra todas las pestañas de un proyecto (p. ej. al detenerlo). Los persistentes
    /// solo se desenganchan.
    func closeAll(for handle: SessionHandle) {
        for slot in slots(for: handle) { closeTab(slot.id, for: handle) }
        counters[handle] = nil
    }

    /// Cierra todas las pestañas de un servidor (al eliminarlo, editarlo o rehacer su
    /// conexión: los persistentes se desenganchan del servicio viejo y siguen en el servidor).
    func closeAll(forServer serverID: Server.ID) {
        for handle in slotsByHandle.keys where handle.serverID == serverID {
            closeAll(for: handle)
        }
        readinessCache[serverID] = nil
        watch.forget(serverID: serverID)
    }

    /// Mata los `claude` de ESTA SESIÓN y espera a que el servidor lo confirme (o a que
    /// falle la conexión). Para el cierre de la app (`applicationShouldTerminate` con
    /// `.terminateLater`): no deja huérfanos en el servidor. Los agentes persistentes NO se
    /// detienen (para eso existen): solo se desenganchan y se deja de sondear.
    func stopAll() async {
        watch.stop()
        for slot in slotsByHandle.values.flatMap({ $0 }) { slot.persistentTab?.session.detach() }
        let sessions = allTabs.map(\.tab.session)
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.stopAndWait() }
            }
        }
    }

    // MARK: - Huérfanos

    /// Al conectar: mata los `claude` del panel que ESTE dispositivo lanzó en el servidor
    /// y ya no tienen una pestaña viva (app cerrada a la fuerza, conexión perdida…). Se
    /// identifican por su id de sesión registrado y la forma exacta de la invocación; un
    /// claude de tmux, de otro dispositivo o ajeno a Argos nunca se toca. Como mucho una
    /// vez cada `cleanupInterval` por servidor (salvo `force`).
    func cleanUpOrphans(serverID: Server.ID, service: any SSHServicing, force: Bool = false, now: Date = Date()) async {
        if !force, let last = lastCleanup[serverID], now.timeIntervalSince(last) < Self.cleanupInterval { return }
        lastCleanup[serverID] = now
        let registered = registry.sessionIDs(serverID: serverID)
        guard !registered.isEmpty else { return }
        do {
            let inventory = try await service.serverAgentInventory()
            let live = Set(allTabs.filter { $0.handle.serverID == serverID && $0.tab.session.isRunning }
                .map(\.tab.session.sessionID))
            let plan = AgentPanelOrphans.plan(inventory: inventory, registered: registered, liveTabSessionIDs: live)
            // Relee el registro: los ids añadidos mientras se leía el inventario (una
            // pestaña nueva) no estaban en la instantánea y deben conservarse.
            let added = registry.sessionIDs(serverID: serverID).filter { !registered.contains($0) }
            registry.replace(plan.registry + added, serverID: serverID)
            let targets = plan.orphans.compactMap { agent -> (pid: Int32, sessionID: String)? in
                if case .panel(let pid) = agent.kind { return (pid, agent.sessionID) }
                return nil
            }
            guard !targets.isEmpty else { return }
            Log.agent.notice("Limpiando \(targets.count, privacy: .public) agentes huérfanos del panel.")
            _ = try await service.runAgentScript(ServerAgentInventory.stopPanel(targets))
        } catch {
            Log.agent.error("No se pudieron limpiar los agentes huérfanos: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// Lo que se sabe de Claude en un servidor (cacheado para no repetir viajes SSH).
struct AgentServerReadiness: Equatable, Sendable {
    let claudePath: String
    let authStatus: ClaudeAuthStatus?
}
