//
//  SessionsColumn.swift
//  Argos
//
//  Columna central: proyectos (carpetas con sesión tmux efímera) y sesiones sueltas
//  de TODOS los servidores, agrupados por servidor y grupo. Lo que se ve de cada
//  servidor (búsqueda, filtro, plegados) lo calcula `VisibleProjectListing`. El sondeo
//  de avisos, sesiones y puertos ya no vive aquí: lo hace `WorkspacePoller` desde el
//  modelo de la app.
//

import AppKit
import SwiftUI

struct SessionsColumn: View {
    @Bindable var model: ArgosAppModel

    @State private var projectForm: ProjectFormRequest?
    @State private var projectConfirmation: ProjectConfirmation?
    @State private var importServer: Server?
    @State private var projectSync: ProjectSyncRequest?
    @State private var renameTarget: SessionAction?
    @State private var killTarget: SessionAction?
    @State private var searchText = ""
    @State private var statusFilter: ProjectStatusFilter = .all
    @State private var isShowingBroadcast = false
    @State private var broadcastPreselect: Set<SessionHandle> = []
    @State private var isShowingResources = false
    @FocusState private var searchFocused: Bool
    @State private var collapsedGroups = CollapsedSessionGroups.shared

    private var servers: [Server] { model.store.servers }
    private var vms: [Server.ID: SessionsViewModel] { model.vms }
    private var terminalStore: TerminalSessionStore { model.terminalStore }

    var body: some View {
        List(selection: $model.selectedSession) {
            ForEach(servers) { server in
                Section {
                    if let vm = vms[server.id], !isServerHidden(server) {
                        ServerSessionsSection(
                            server: server,
                            vm: vm,
                            terminalStore: terminalStore,
                            listing: listing(for: server, vm: vm),
                            statusFilter: statusFilter,
                            renameTarget: $renameTarget,
                            killTarget: $killTarget,
                            projectForm: $projectForm,
                            projectConfirmation: $projectConfirmation,
                            importServer: $importServer,
                            projectSync: $projectSync,
                            onBroadcast: { presentBroadcast(preselecting: [$0]) }
                        )
                    }
                } header: {
                    ServerSectionHeader(
                        server: server,
                        vm: vms[server.id],
                        terminalStore: terminalStore,
                        onNewProject: { projectForm = .new(server) },
                        onImport: { importServer = server },
                        onStopBackground: { projectConfirmation = .stopBackground(server, $0) }
                    )
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { WorkspaceFooter() }
        .background {
            Button("Buscar proyectos y sesiones") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .onChange(of: model.selectedSession) { _, handle in revealSelection(handle) }
        .navigationTitle("Proyectos")
        .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        .toolbar { toolbarContent }
        .modifier(projectSheets)
        .modifier(sessionSheets)
    }

    // MARK: - Lo que se ve

    /// Lo visible de un servidor con la búsqueda, el filtro y los plegados actuales.
    private func listing(for server: Server, vm: SessionsViewModel) -> VisibleProjectListing {
        let source = vm.projectListing
        return VisibleProjectListing(
            entries: source.entries,
            looseSessions: source.looseSessions,
            query: searchText,
            statusFilter: statusFilter,
            status: { terminalStore.status(of: $0, serverID: server.id) },
            sessionStatus: { terminalStore.status(of: $0, serverID: server.id) },
            isCollapsed: { collapsedGroups.isCollapsed(serverID: server.id, group: $0) }
        )
    }

    /// Servidores cargados y a la vista (los plegados cuentan como ocultos).
    private var visibleLoadedServers: [(Server, SessionsViewModel)] {
        servers.compactMap { server in
            guard let vm = vms[server.id], case .loaded = vm.state, !isServerHidden(server) else { return nil }
            return (server, vm)
        }
    }

    private var header: some View {
        WorkspaceHeader(
            searchText: $searchText,
            statusFilter: $statusFilter,
            searchFocused: $searchFocused,
            projectCount: servers.reduce(0) { $0 + (vms[$1.id]?.projectListing.entries.count ?? 0) },
            runningCount: servers.reduce(0) { $0 + (vms[$1.id]?.sessions.count ?? 0) },
            statusCounts: statusCounts,
            canCreateProject: !(activeVM?.isWorking ?? true),
            onNewProject: { if let server = activeServer { projectForm = .new(server) } },
            onSubmitSearch: openFirstSearchResult
        )
    }

    private var statusCounts: [ProjectStatusFilter: Int] {
        VisibleProjectListing.merging(visibleLoadedServers.map { server, vm in
            let source = vm.projectListing
            return VisibleProjectListing.statusCounts(
                entries: source.entries,
                looseSessions: source.looseSessions,
                status: { terminalStore.status(of: $0, serverID: server.id) },
                sessionStatus: { terminalStore.status(of: $0, serverID: server.id) }
            )
        })
    }

    /// Intro en la búsqueda: el primer elemento visible en el orden en que se pinta.
    private func openFirstSearchResult() {
        for (server, vm) in visibleLoadedServers {
            if let name = listing(for: server, vm: vm).firstVisibleSessionName {
                model.selectedSession = SessionHandle(serverID: server.id, sessionID: name)
                searchFocused = false
                return
            }
        }
    }

    /// Una selección de ⌘K puede quedar fuera de la búsqueda o en un grupo plegado.
    private func revealSelection(_ handle: SessionHandle?) {
        guard let handle, let vm = vms[handle.serverID] else { return }
        let project = vm.project(forSession: handle.sessionID)
        let matches = project.map { VisibleProjectListing.matches(ProjectEntry(project: $0, session: nil), query: searchText) }
            ?? vm.session(withID: handle.sessionID).map { VisibleProjectListing.matches($0, query: searchText) }
            ?? true
        if !matches { searchText = "" }
        let group = project?.group ?? (project == nil ? VisibleProjectListing.looseGroupName : SessionGrouping.ungroupedName)
        if collapsedGroups.isServerCollapsed(handle.serverID) {
            collapsedGroups.toggleServer(handle.serverID)
        }
        if collapsedGroups.isCollapsed(serverID: handle.serverID, group: group) {
            collapsedGroups.toggle(serverID: handle.serverID, group: group)
        }
    }

    /// Un servidor plegado oculta su contenido, salvo mientras se busca o filtra.
    private func isServerHidden(_ server: Server) -> Bool {
        searchText.isEmpty && statusFilter == .all && collapsedGroups.isServerCollapsed(server.id)
    }

    // MARK: - Barra de herramientas

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let server = activeServer { projectForm = .new(server) }
            } label: {
                Label("Nuevo proyecto", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help(activeServer.map { "Crear un proyecto en \($0.name) (⌘N)" } ?? "Selecciona un servidor en la barra lateral")
            .disabled(activeVM?.isWorking ?? true)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { presentBroadcast(preselecting: model.selectedSession.map { [$0] } ?? []) } label: {
                Label("Enviar comando…", systemImage: "paperplane")
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .help("Enviar un comando a una o varias sesiones (⌥⌘K)")
            .disabled(broadcastTargets.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { isShowingResources.toggle() } label: {
                Label("Recursos del servidor", systemImage: "gauge.with.dots.needle.33percent")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(activeServer.map { "CPU, memoria y disco de \($0.name) (⌥⌘I)" } ?? "Selecciona un servidor en la barra lateral")
            .disabled(activeVM == nil)
            .popover(isPresented: $isShowingResources, arrowEdge: .bottom) {
                if let server = activeServer, let vm = activeVM {
                    ServerResourcesView(serverName: server.name, service: vm.service)
                        .id(server.id)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.refreshAll() } } label: {
                Label("Refrescar todo", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Volver a consultar las sesiones de los servidores conectados (⌘R)")
        }
    }

    private var activeServer: Server? {
        model.selectedServerID.flatMap { id in servers.first { $0.id == id } }
    }

    private var activeVM: SessionsViewModel? {
        model.selectedServerID.flatMap { vms[$0] }
    }

    /// Todas las sesiones cargadas (de todos los servidores) como destinos de broadcast.
    private var broadcastTargets: [BroadcastTarget] {
        servers.flatMap { server -> [BroadcastTarget] in
            guard let vm = vms[server.id] else { return [] }
            return vm.sessions.map { session in
                BroadcastTarget(
                    handle: SessionHandle(serverID: server.id, sessionID: session.id),
                    serverName: server.name,
                    sessionName: session.name,
                    service: vm.service
                )
            }
        }
    }

    private func presentBroadcast(preselecting handles: Set<SessionHandle>) {
        broadcastPreselect = handles
        isShowingBroadcast = true
    }

    // MARK: - Hojas y confirmaciones

    private var projectSheets: SessionsColumnProjectSheets {
        SessionsColumnProjectSheets(
            model: model,
            projectForm: $projectForm,
            projectSync: $projectSync,
            importServer: $importServer,
            projectConfirmation: $projectConfirmation
        )
    }

    private var sessionSheets: SessionsColumnSessionSheets {
        SessionsColumnSessionSheets(
            model: model,
            renameTarget: $renameTarget,
            killTarget: $killTarget,
            isShowingBroadcast: $isShowingBroadcast,
            broadcastTargets: broadcastTargets,
            broadcastPreselect: broadcastPreselect
        )
    }
}
