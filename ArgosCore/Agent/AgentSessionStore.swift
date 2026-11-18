//
//  AgentSessionStore.swift
//  Argos
//
//  Pool de agentes de Claude Code por proyecto/sesión (`SessionHandle`), con VARIAS
//  conversaciones en pestañas por cada uno (como las ventanas del terminal). Mantiene
//  los agentes vivos aunque cambies de proyecto o de pestaña (Terminal/Archivos/Agente).
//
//  Al llegar al tope NO cierra nada por su cuenta: la vista pregunta cuál cerrar. Las
//  conversaciones cerradas se recuerdan para reanudarlas (`--resume`). Al salir de la app
//  `stopAll()` mata todos los `claude`; al conectar, `cleanUpOrphans` mata los que este
//  dispositivo lanzó y ya no tienen pestaña viva.
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
        AgentTab.title(items: session.state.items) ?? "Conversación \(number)"
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

    private var tabsByHandle: [SessionHandle: [AgentTab]] = [:]
    private var selectedByHandle: [SessionHandle: UUID] = [:]
    private var counters: [SessionHandle: Int] = [:]
    private var closedByHandle: [SessionHandle: [ClosedAgentConversation]] = [:]
    /// Comprobaciones de Claude ya hechas por servidor: al cambiar de proyecto se muestran
    /// las pestañas al instante y se verifica en segundo plano.
    var readinessCache: [Server.ID: AgentServerReadiness] = [:]
    @ObservationIgnored private var lastCleanup: [Server.ID: Date] = [:]
    @ObservationIgnored private let registry: AgentPanelRegistry

    /// Tope de agentes vivos a la vez EN TOTAL (cada uno es un `claude` remoto que ocupa
    /// ~0,5 GB en el servidor).
    static let maxLiveSessions = AgentLaunchGuard.maxLiveAgents
    /// Conversaciones cerradas que se recuerdan por proyecto.
    static let maxClosedConversations = 10
    /// Entre dos limpiezas de huérfanos del mismo servidor.
    static let cleanupInterval: TimeInterval = 120

    init(registry: AgentPanelRegistry = AgentPanelRegistry()) {
        self.registry = registry
    }

    func tabs(for handle: SessionHandle) -> [AgentTab] {
        tabsByHandle[handle] ?? []
    }

    func selectedTab(for handle: SessionHandle) -> AgentTab? {
        let tabs = tabs(for: handle)
        return tabs.first { $0.id == selectedByHandle[handle] } ?? tabs.last
    }

    func select(_ tabID: UUID, for handle: SessionHandle) {
        selectedByHandle[handle] = tabID
    }

    /// Todas las pestañas con su proyecto (para elegir cuál cerrar al llegar al tope).
    var allTabs: [AgentTabEntry] {
        tabsByHandle.flatMap { handle, tabs in tabs.map { AgentTabEntry(handle: handle, tab: $0) } }
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
        let number = (counters[handle] ?? 0) + 1
        counters[handle] = number
        let tab = AgentTab(
            id: UUID(),
            number: number,
            session: ClaudeAgentSession(
                service: service, command: command, workingDirectory: workingDirectory,
                oauthToken: oauthToken, sessionID: sessionID, initialState: initialState
            ),
            permissionMode: permissionMode
        )
        registry.record(sessionID, serverID: handle.serverID)
        tabsByHandle[handle, default: []].append(tab)
        selectedByHandle[handle] = tab.id
        return tab
    }

    /// Reanuda en la MISMA pestaña una conversación terminada (`--resume`), conservando lo
    /// que ya se veía. `command` debe ser `ClaudeAgentCommand.build(…, resume: true)`.
    func resumeTab(_ tabID: UUID, for handle: SessionHandle, service: any SSHServicing, command: String, oauthToken: String?) {
        guard var tabs = tabsByHandle[handle], let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let old = tabs[index]
        guard !old.session.isRunning else { return }
        let session = ClaudeAgentSession(
            service: service, command: command, workingDirectory: old.session.workingDirectory,
            oauthToken: oauthToken, sessionID: old.session.sessionID, initialState: old.session.state
        )
        tabs[index] = AgentTab(id: old.id, number: old.number, session: session, permissionMode: old.permissionMode)
        tabsByHandle[handle] = tabs
        registry.record(old.session.sessionID, serverID: handle.serverID)
    }

    /// Reabre una conversación cerrada en una pestaña nueva (`--resume`).
    @discardableResult
    func reopen(
        _ closed: ClosedAgentConversation,
        for handle: SessionHandle,
        service: any SSHServicing,
        command: String,
        oauthToken: String?
    ) -> AgentTab {
        closedByHandle[handle]?.removeAll { $0.sessionID == closed.sessionID }
        return newTab(
            for: handle, service: service, command: command, workingDirectory: closed.workingDirectory,
            oauthToken: oauthToken, permissionMode: closed.permissionMode,
            sessionID: closed.sessionID, initialState: closed.state
        )
    }

    func closedConversations(for handle: SessionHandle) -> [ClosedAgentConversation] {
        closedByHandle[handle] ?? []
    }

    /// Cierra una conversación (mata su `claude` remoto). Si tenía mensajes, se recuerda
    /// para poder reanudarla.
    func closeTab(_ tabID: UUID, for handle: SessionHandle) {
        guard var tabs = tabsByHandle[handle], let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        tab.session.stop()
        remember(tab, for: handle)
        tabs.remove(at: index)
        tabsByHandle[handle] = tabs.isEmpty ? nil : tabs
        if selectedByHandle[handle] == tabID {
            selectedByHandle[handle] = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
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

    /// Cierra todas las conversaciones de un proyecto (p. ej. al detenerlo).
    func closeAll(for handle: SessionHandle) {
        for tab in tabs(for: handle) { closeTab(tab.id, for: handle) }
        counters[handle] = nil
    }

    /// Cierra todos los agentes de un servidor (al eliminarlo/editarlo).
    func closeAll(forServer serverID: Server.ID) {
        for handle in tabsByHandle.keys where handle.serverID == serverID {
            closeAll(for: handle)
        }
        readinessCache[serverID] = nil
    }

    /// Mata TODOS los `claude` del panel y espera a que el servidor lo confirme (o a que
    /// falle la conexión). Para el cierre de la app (`applicationShouldTerminate` con
    /// `.terminateLater`): no deja huérfanos en el servidor.
    func stopAll() async {
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
            registry.replace(plan.registry, serverID: serverID)
            let targets = plan.orphans.compactMap { agent -> (pid: Int32, sessionID: String)? in
                if case .panel(let pid) = agent.kind { return (pid, agent.sessionID) }
                return nil
            }
            guard !targets.isEmpty else { return }
            Log.agent.notice("Limpiando \(targets.count, privacy: .public) agentes huérfanos del panel.")
            _ = try await service.runAgentScript(ServerAgentInventory.stopPanel(targets))
        } catch {
            Log.agent.error("No se pudieron limpiar los agentes huérfanos: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Lo que se sabe de Claude en un servidor (cacheado para no repetir viajes SSH).
struct AgentServerReadiness: Equatable, Sendable {
    let claudePath: String
    let authStatus: ClaudeAuthStatus?
}
