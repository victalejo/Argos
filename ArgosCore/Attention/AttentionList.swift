//
//  AttentionList.swift
//  ArgosCore
//
//  La bandeja de atención como UNA lista entre todos los servidores, ordenada por
//  urgencia (lógica pura). Se construye con lo que la app ya tiene: el último estado de
//  Claude que trajo el sondeador, las pestañas del panel Agente, las solicitudes de
//  puertos, los envíos y lo que recuerda `AttentionInbox`. No añade sondeos.
//

import Foundation

enum AttentionList {

    /// Estado de un servidor conectado.
    struct ServerInput: Sendable {
        let serverID: Server.ID
        let claude: ClaudeActivitySnapshot
        let projects: [Project]
    }

    /// Una conversación del panel Agente con un permiso pendiente.
    struct AgentPermissionInput: Sendable {
        let handle: SessionHandle
        let tabID: UUID
        let conversation: String
        let toolName: String
    }

    struct PortInput: Sendable {
        let serverID: Server.ID
        let request: PortForwardRequest
    }

    /// Un envío terminado o fallido que sigue a la vista.
    struct SyncInput: Sendable {
        let serverID: Server.ID
        let projectID: UUID
        let projectName: String
        let failed: Bool
        let message: String
    }

    static func build(
        inbox: AttentionInbox,
        servers: [ServerInput],
        agents: [AgentPermissionInput] = [],
        ports: [PortInput] = [],
        syncs: [SyncInput] = []
    ) -> [AttentionItem] {
        let projects = Dictionary(servers.map { ($0.serverID, $0.projects) }, uniquingKeysWith: { first, _ in first })
        var items = servers.flatMap(waitingItems)
        items += agents.map(agentItem)
        items += inbox.failedCI.values.map { ciItem($0, projects: projects[$0.serverID] ?? []) }
        items += ports.map(portItem)
        items += syncs.map(syncItem)
        items += inbox.unseenDone.values.map { doneItem($0, projects: projects[$0.serverID] ?? []) }
        let order = Dictionary(servers.enumerated().map { ($1.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        return items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            let left = order[lhs.serverID] ?? .max, right = order[rhs.serverID] ?? .max
            if left != right { return left < right }
            return (lhs.title, lhs.id) < (rhs.title, rhs.id)
        }
    }

    /// El siguiente al actual (o el primero), para «Ir al siguiente que me necesita».
    static func next(after current: String?, in items: [AttentionItem]) -> AttentionItem? {
        guard let current, let index = items.firstIndex(where: { $0.id == current }) else { return items.first }
        return items[(index + 1) % items.count]
    }

    /// Cuántos piden una respuesta (insignia del Dock).
    static func responseCount(_ items: [AttentionItem]) -> Int {
        items.filter(\.needsResponse).count
    }

    // MARK: - Elementos

    private static func waitingItems(_ server: ServerInput) -> [AttentionItem] {
        var seen = Set<String>()
        return server.claude.panes.compactMap { pane in
            guard pane.activity == .waiting, seen.insert("\(pane.session)\u{0}\(pane.window)").inserted else { return nil }
            let handle = SessionHandle(serverID: server.serverID, sessionID: pane.session)
            return AttentionItem(
                id: "waiting|\(server.serverID)|\(pane.session)|\(pane.window)",
                kind: .claudeWaiting,
                serverID: server.serverID,
                title: displayName(pane.session, projects: server.projects),
                detail: "Ventana \(pane.window) · necesita permiso o una respuesta",
                destination: .terminal(handle, window: pane.window)
            )
        }
    }

    private static func agentItem(_ agent: AgentPermissionInput) -> AttentionItem {
        AttentionItem(
            id: "agent|\(agent.tabID)",
            kind: .agentPermission,
            serverID: agent.handle.serverID,
            title: agent.conversation,
            detail: "Pide permiso para usar \(agent.toolName)",
            destination: .agent(agent.handle, tabID: agent.tabID)
        )
    }

    private static func ciItem(_ ci: AttentionInbox.FailedCI, projects: [Project]) -> AttentionItem {
        let project = projects.first { $0.path == ci.root }
        let destination: AttentionDestination = project.map {
            .project(SessionHandle(serverID: ci.serverID, sessionID: $0.sessionName), mode: .changes)
        } ?? .server(ci.serverID)
        return AttentionItem(
            id: ci.id, kind: .ciFailed, serverID: ci.serverID,
            title: ci.name, detail: ci.summary, destination: destination
        )
    }

    private static func portItem(_ port: PortInput) -> AttentionItem {
        let note = port.request.note.isEmpty ? "Claude quiere mostrártelo en este dispositivo" : port.request.note
        return AttentionItem(
            id: "port|\(port.serverID)|\(port.request.port)",
            kind: .portRequest,
            serverID: port.serverID,
            title: "Puerto \(port.request.port)",
            detail: note,
            destination: .server(port.serverID)
        )
    }

    private static func syncItem(_ sync: SyncInput) -> AttentionItem {
        AttentionItem(
            id: "sync|\(sync.projectID)",
            kind: sync.failed ? .syncFailed : .syncFinished,
            serverID: sync.serverID,
            title: sync.projectName,
            detail: sync.message,
            destination: .sync(serverID: sync.serverID, projectID: sync.projectID)
        )
    }

    private static func doneItem(_ done: AttentionInbox.UnseenDone, projects: [Project]) -> AttentionItem {
        AttentionItem(
            id: done.id,
            kind: .claudeDone,
            serverID: done.serverID,
            title: displayName(done.session, projects: projects),
            detail: "Ventana \(done.window) · terminó",
            destination: .terminal(SessionHandle(serverID: done.serverID, sessionID: done.session), window: done.window)
        )
    }

    /// Nombre del proyecto de la sesión (o la sesión, si es suelta).
    private static func displayName(_ session: String, projects: [Project]) -> String {
        projects.first { $0.sessionName == session }?.name ?? session
    }
}
