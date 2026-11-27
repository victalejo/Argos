//
//  ArgosAppModel+Attention.swift
//  Argos
//
//  La bandeja de atención en el Mac: la lista (con lo que el modelo ya tiene: el estado de
//  Claude del sondeador, el panel Agente, las solicitudes de puertos y los envíos), abrir
//  un elemento en su sitio y «Ir al siguiente que me necesita». No añade sondeos.
//

import AppKit

/// Ajustes de la bandeja (activados por defecto).
enum AttentionSettings {
    static let showsMenuBarExtraKey = "attention.showsMenuBarExtra"
    static let showsDockBadgeKey = "attention.showsDockBadge"

    /// Se publica al cambiar un ajuste de la bandeja (la insignia se recalcula).
    static let didChange = Notification.Name("ArgosAttentionSettingsDidChange")

    static var showsDockBadge: Bool {
        UserDefaults.standard.object(forKey: showsDockBadgeKey) as? Bool ?? true
    }
}

/// Elementos de un servidor, para la lista agrupada.
struct AttentionGroup: Identifiable {
    let server: Server
    let items: [AttentionItem]
    var id: Server.ID { server.id }
}

extension ArgosAppModel {

    /// Lo que espera al usuario en todos los servidores, por urgencia.
    var attentionItems: [AttentionItem] {
        AttentionList.build(
            inbox: attentionInbox,
            servers: attentionServerInputs,
            agents: attentionAgentInputs,
            ports: attentionPortInputs,
            syncs: attentionSyncInputs,
            persistentAgents: attentionPersistentInputs,
            reviews: attentionReviewInputs
        )
    }

    /// La misma lista agrupada por servidor (en el orden de la barra lateral).
    var attentionGroups: [AttentionGroup] {
        let items = attentionItems
        return store.servers.compactMap { server in
            let own = items.filter { $0.serverID == server.id }
            return own.isEmpty ? nil : AttentionGroup(server: server, items: own)
        }
    }

    func serverName(_ id: Server.ID) -> String {
        store.server(withID: id)?.name ?? "servidor"
    }

    // MARK: - Abrir

    /// Abre la ventana en el sitio del elemento. Lo informativo deja de estar pendiente.
    func openAttention(_ item: AttentionItem) {
        lastAttentionID = item.id
        attentionInbox.resolve(id: item.id)
        showMainWindow()
        switch item.destination {
        case .terminal(let handle, let window):
            open(NotificationRoute(serverID: handle.serverID, session: handle.sessionID, window: window))
        case .agent(let handle, let tabID):
            agentStore.select(tabID, for: handle)
            open(handle, mode: .agent)
        case .persistentAgent(let serverID, let agentID):
            openPersistentAgent(serverID: serverID, agentID: agentID)
        case .project(let handle, let mode):
            open(handle, mode: mode)
        case .server(let id):
            selectedServerID = id
            loadSelectedIfNeeded()
        case .sync(let serverID, let projectID):
            openSync(serverID: serverID, projectID: projectID)
        case .taskReview(let serverID, _, let session):
            openTaskReview(serverID: serverID, session: session)
        }
    }

    /// «Ir al siguiente que me necesita» (⌘J): recorre la bandeja en orden.
    func openNextAttention() {
        guard let next = AttentionList.next(after: lastAttentionID, in: attentionItems) else {
            NSSound.beep()
            return
        }
        openAttention(next)
    }

    private func openSync(serverID: Server.ID, projectID: UUID) {
        guard let job = ProjectSyncCenter.shared.job(forProject: projectID) else { return }
        let handle = SessionHandle(serverID: serverID, sessionID: job.project.sessionName)
        selectedServerID = serverID
        selectedSession = handle
        requestedSync = job.request
    }

    /// Se eligió una sesión (en la lista, ⌘K, un aviso…): sus «terminó» quedan vistos.
    func didSelect(_ handle: SessionHandle?) {
        guard let handle else { return }
        attentionInbox.markSeen(serverID: handle.serverID, session: handle.sessionID)
    }

    // MARK: - Insignia del Dock

    /// Número del Dock: solo lo que pide una respuesta (y si el ajuste lo permite). Se
    /// vuelve a calcular solo cuando cambia algo de lo que lee.
    func observeDockBadge() {
        startPersistentAgentWatch()
        withObservationTracking {
            updateDockBadge()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeDockBadge() }
        }
    }

    func updateDockBadge() {
        let count = AttentionSettings.showsDockBadge ? AttentionList.responseCount(attentionItems) : 0
        let label = count > 0 ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    // MARK: - Agentes persistentes

    /// Sondeo de fondo de los agentes persistentes de los servidores conectados (ver
    /// `PersistentAgentWatch`). Idempotente; no arranca durante el cierre.
    private func startPersistentAgentWatch() {
        guard !agentStore.watch.isRunning, !isShuttingDown else { return }
        agentStore.watch.start { [weak self] in
            guard let self else { return [] }
            return self.store.servers.compactMap { server -> (Server.ID, any SSHServicing)? in
                guard let vm = self.vms[server.id], case .loaded = vm.state else { return nil }
                return (server.id, vm.service)
            }
        }
    }

    /// Abre el agente en una pestaña del panel Agente de su proyecto (la carpeta del agente).
    private func openPersistentAgent(serverID: Server.ID, agentID: String) {
        agentStore.watch.markSeen(serverID: serverID, agentID: agentID)
        if let existing = agentStore.persistentTab(serverID: serverID, agentID: agentID) {
            agentStore.select(existing.tab.id, for: existing.handle)
            open(existing.handle, mode: .agent)
            return
        }
        guard let vm = vms[serverID], let agent = agentStore.watch.overview(serverID: serverID, agentID: agentID),
              let project = vm.projects.first(where: { AgentFolderMatch.same($0.path, agent.meta.workingDirectory) })
        else {
            Log.agent.notice("El agente del aviso no tiene un proyecto en este Mac: se abre su servidor.")
            selectedServerID = serverID
            loadSelectedIfNeeded()
            return
        }
        let handle = SessionHandle(serverID: serverID, sessionID: project.sessionName)
        agentStore.openPersistent(agent.info, for: handle, service: vm.service)
        open(handle, mode: .agent)
    }

    // MARK: - Entradas

    private var attentionServerInputs: [AttentionList.ServerInput] {
        store.servers.compactMap { server in
            guard let vm = vms[server.id], case .loaded = vm.state else { return nil }
            return .init(serverID: server.id, claude: vm.claudeActivity, projects: vm.projects)
        }
    }

    private var attentionAgentInputs: [AttentionList.AgentPermissionInput] {
        agentStore.allTabs.compactMap { entry in
            guard let permission = entry.tab.session.state.pendingPermission else { return nil }
            return .init(
                handle: entry.handle, tabID: entry.tab.id, conversation: entry.tab.title,
                toolName: permission.displayName ?? permission.toolName
            )
        }
    }

    /// Agentes persistentes: los de pestañas abiertas con su estado en vivo; el resto, del
    /// último sondeo de fondo.
    private var attentionPersistentInputs: [PersistentAgentAttentionTracker.Notice] {
        let attached = agentStore.persistentTabs.filter { $0.tab.session.isAttached }
        let live = attached.compactMap { entry -> PersistentAgentAttentionTracker.Notice? in
            guard let permission = entry.tab.session.state.pendingPermission else { return nil }
            return .init(
                serverID: entry.handle.serverID, agentID: entry.tab.session.id, title: entry.tab.title,
                workingDirectory: entry.tab.session.meta.workingDirectory,
                kind: .permission(tool: permission.displayName ?? permission.toolName)
            )
        }
        let watch = agentStore.watch
        return live + watch.tracker.notices(agents: watch.agents, excluding: Set(attached.map(\.tab.session.id)))
    }

    private var attentionPortInputs: [AttentionList.PortInput] {
        store.servers.compactMap { server in
            portRequests[server.id]?.current.map { .init(serverID: server.id, request: $0) }
        }
    }

    private var attentionSyncInputs: [AttentionList.SyncInput] {
        ProjectSyncCenter.shared.jobs.values.compactMap { job in
            let outcome: (failed: Bool, message: String)
            switch job.phase {
            case .done(let message, _): outcome = (false, message)
            case .failed(let message): outcome = (true, message)
            default: return nil
            }
            // A la vista en su hoja: ya se está mirando.
            guard !job.isPresented else { return nil }
            return .init(
                serverID: job.request.server.id, projectID: job.project.id,
                projectName: job.project.name, failed: outcome.failed, message: outcome.message
            )
        }
    }
}
