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

    /// Un encargo que el revisor automático dejó en pausa.
    struct ReviewInput: Sendable {
        let serverID: Server.ID
        let block: ClaudeTaskReviewBlock
    }

    /// Un proyecto con la cola frenada por su presupuesto.
    struct BudgetInput: Sendable {
        let serverID: Server.ID
        let block: ClaudeBudgetBlock
    }

    static func build(
        inbox: AttentionInbox,
        servers: [ServerInput],
        agents: [AgentPermissionInput] = [],
        ports: [PortInput] = [],
        syncs: [SyncInput] = [],
        persistentAgents: [PersistentAgentAttentionTracker.Notice] = [],
        reviews: [ReviewInput] = [],
        budgets: [BudgetInput] = [],
        now: Date = Date()
    ) -> [AttentionItem] {
        let projects = Dictionary(servers.map { ($0.serverID, $0.projects) }, uniquingKeysWith: { first, _ in first })
        var items = servers.flatMap(waitingItems)
        items += agents.map(agentItem)
        items += persistentAgents.map { persistentItem($0, projects: projects[$0.serverID] ?? []) }
        items += inbox.failedCI.values.map { ciItem($0, projects: projects[$0.serverID] ?? []) }
        items += reviews.map { reviewItem($0, projects: projects[$0.serverID] ?? []) }
        items += ports.map(portItem)
        items += syncs.map(syncItem)
        items += budgets.map { budgetItem($0, projects: projects[$0.serverID] ?? [], now: now) }
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
                detail: String(localized: "Ventana \(pane.window) · necesita permiso o una respuesta"),
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
            detail: String(localized: "Pide permiso para usar \(agent.toolName)"),
            destination: .agent(agent.handle, tabID: agent.tabID)
        )
    }

    private static func persistentItem(_ notice: PersistentAgentAttentionTracker.Notice, projects: [Project]) -> AttentionItem {
        let project = projects.first { AgentFolderMatch.same($0.path, notice.workingDirectory) }
        let kind: AttentionKind
        let detail: String
        switch notice.kind {
        case .permission(let tool):
            kind = .agentPermission
            detail = String(localized: "Agente en el servidor · pide permiso para usar \(tool)")
        case .finished(let summary, let isError):
            kind = .claudeDone
            let text = summary.map { String($0.prefix(120)) } ?? (isError ? String(localized: "terminó con un error") : String(localized: "terminó"))
            detail = String(localized: "Agente en el servidor · \(text)")
        }
        return AttentionItem(
            id: notice.id, kind: kind, serverID: notice.serverID,
            title: project?.name ?? notice.title, detail: detail,
            destination: .persistentAgent(serverID: notice.serverID, agentID: notice.agentID)
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

    private static func reviewItem(_ review: ReviewInput, projects: [Project]) -> AttentionItem {
        let project = projects.first { ClaudeUsageProjects.key(forPath: $0.path) == review.block.projectKey }
        let title = review.block.title.isEmpty ? String(localized: "Encargo") : review.block.title
        return AttentionItem(
            id: "review|\(review.serverID)|\(review.block.id)",
            kind: .reviewBlocked,
            serverID: review.serverID,
            title: project?.name ?? review.block.projectKey,
            detail: String(localized: "\(title) · no se subió: decide si subirlo igualmente o pedir el arreglo"),
            destination: .taskReview(serverID: review.serverID, block: review.block, session: project?.sessionName)
        )
    }

    private static func budgetItem(_ input: BudgetInput, projects: [Project], now: Date) -> AttentionItem {
        let project = projects.first { ClaudeUsageProjects.key(forPath: $0.path) == input.block.projectKey }
        let destination: AttentionDestination = project.map {
            .terminal(SessionHandle(serverID: input.serverID, sessionID: $0.sessionName), window: nil)
        } ?? .server(input.serverID)
        return AttentionItem(
            id: "budget|\(input.serverID)|\(input.block.id)",
            kind: .budgetPaused,
            serverID: input.serverID,
            title: project?.name ?? ClaudeUsageProjects.fallbackName(input.block.projectKey),
            detail: input.block.message(now: now),
            destination: destination
        )
    }

    private static func portItem(_ port: PortInput) -> AttentionItem {
        let note = port.request.note.isEmpty ? String(localized: "Claude quiere mostrártelo en este dispositivo") : port.request.note
        return AttentionItem(
            id: "port|\(port.serverID)|\(port.request.port)",
            kind: .portRequest,
            serverID: port.serverID,
            title: String(localized: "Puerto \(String(port.request.port))"),
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
            detail: String(localized: "Ventana \(done.window) · terminó"),
            destination: .terminal(SessionHandle(serverID: done.serverID, sessionID: done.session), window: done.window)
        )
    }

    /// Nombre del proyecto de la sesión (o la sesión, si es suelta).
    private static func displayName(_ session: String, projects: [Project]) -> String {
        projects.first { $0.sessionName == session }?.name ?? session
    }
}
