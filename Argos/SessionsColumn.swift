//
//  SessionsColumn.swift
//  Argos
//
//  Columna central: proyectos (carpetas con sesión tmux efímera) y sesiones sueltas
//  de TODOS los servidores, agrupados por servidor y grupo.
//

import AppKit
import SwiftUI

struct SessionsColumn: View {
    let servers: [Server]
    let vms: [Server.ID: SessionsViewModel]
    /// Pool de terminales en vivo (estado de cada sesión).
    let terminalStore: TerminalSessionStore
    /// Agentes de Claude (se cierran al detener un proyecto para liberar memoria).
    let agentStore: AgentSessionStore
    /// Servidor activo en la sidebar (para "Nueva sesión").
    let activeServerID: Server.ID?
    @Binding var selection: SessionHandle?

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List(selection: $selection) {
            ForEach(servers) { server in
                Section {
                    if let vm = vms[server.id] {
                        ServerSessionsSection(
                            server: server,
                            vm: vm,
                            terminalStore: terminalStore,
                            filter: searchText,
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
                    serverHeader(server)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .safeAreaInset(edge: .top, spacing: 0) { workspaceHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { workspaceFooter }
        .background {
            Button("Buscar proyectos y sesiones") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .task { await pollClaudeActivity() }
        .onChange(of: selection) { _, handle in
            revealSelection(handle)
        }
        .navigationTitle("Proyectos")
        .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        .toolbar { toolbarContent }
        .sheet(item: $projectForm) { request in
            if let vm = vms[request.server.id] {
                if case .worktrees(_, let project) = request {
                    WorktreesSheet(project: project, vm: vm)
                } else {
                    ProjectFormSheet(request: request, vm: vm)
                }
            }
        }
        .sheet(item: $projectSync) { request in
            if let vm = vms[request.server.id] {
                ProjectSyncSheet(
                    request: request,
                    vm: vm,
                    closeLiveViews: { project in
                        let handle = SessionHandle(serverID: request.server.id, sessionID: project.sessionName)
                        terminalStore.close(handle)
                        agentStore.closeAll(for: handle)
                    },
                    onClose: { projectSync = nil }
                )
            }
        }
        .sheet(item: $importServer) { server in
            if let vm = vms[server.id] {
                ImportProjectsSheet(server: server, vm: vm)
            }
        }
        .confirmationDialog(
            projectConfirmation?.title ?? "",
            isPresented: Binding(
                get: { projectConfirmation != nil },
                set: { if !$0 { projectConfirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: projectConfirmation
        ) { confirmation in
            Button(confirmation.actionLabel, role: .destructive) { perform(confirmation) }
            Button("Cancelar", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(isPresented: $isShowingBroadcast) {
            SendCommandSheet(
                targets: broadcastTargets,
                initialSelection: broadcastPreselect,
                onClose: { isShowingBroadcast = false }
            )
        }
        .sheet(item: $renameTarget) { action in
            SessionNameSheet(mode: .rename(current: action.session.name)) { newName in
                if let vm = vms[action.server.id] {
                    try await vm.renameSession(action.session, to: newName)
                }
            }
        }
        .confirmationDialog(
            killTarget.map { "¿Matar la sesión '\($0.session.name)'?" } ?? "¿Matar la sesión?",
            isPresented: killDialogBinding,
            titleVisibility: .visible,
            presenting: killTarget
        ) { action in
            Button("Matar", role: .destructive) {
                Task {
                    if let vm = vms[action.server.id] { await vm.kill(action.session) }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Se cerrará y se perderá todo lo que corra en ella.")
        }
        // Errores de operaciones sin formulario propio (matar): antes se asignaban a
        // `vm.operationError` y NINGUNA vista los leía (fallo silencioso). Aquí se muestran.
        .alert(
            "No se pudo completar la operación",
            isPresented: operationErrorBinding,
            presenting: vmWithError?.operationError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var projectCount: Int {
        servers.reduce(0) { $0 + (vms[$1.id]?.projectListing.entries.count ?? 0) }
    }

    /// A selection from ⌘K can be outside the current search or a collapsed group.
    private func revealSelection(_ handle: SessionHandle?) {
        guard let handle, let vm = vms[handle.serverID] else { return }
        let project = vm.project(forSession: handle.sessionID)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let values = [handle.sessionID, project?.path ?? ""]
        if !query.isEmpty && !values.contains(where: {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }) {
            searchText = ""
        }
        let group = project?.group ?? (project == nil ? "Sesiones sueltas" : SessionGrouping.ungroupedName)
        let collapsed = CollapsedSessionGroups.shared
        if collapsed.isCollapsed(serverID: handle.serverID, group: group) {
            collapsed.toggle(serverID: handle.serverID, group: group)
        }
    }

    private var runningCount: Int {
        servers.reduce(0) { $0 + (vms[$1.id]?.sessions.count ?? 0) }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ESPACIO DE TRABAJO")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Proyectos")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                }
                Spacer()
                Button {
                    if let server = activeServer { projectForm = .new(server) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 9))
                .disabled(activeVM?.isWorking ?? true)
                .help("Nuevo proyecto (⌘N)")
                .accessibilityLabel("Nuevo proyecto")
            }

            HStack(spacing: 14) {
                Label("\(projectCount) proyectos", systemImage: "folder")
                Label("\(runningCount) en marcha", systemImage: "bolt.fill")
                    .foregroundStyle(.teal)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Buscar proyectos o sesiones…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onKeyPress(.escape) {
                        if searchText.isEmpty { searchFocused = false }
                        else { searchText = "" }
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let handle = firstVisibleSearchResult {
                            selection = handle
                            searchFocused = false
                        }
                        // Enter belongs to search, including when there are no results.
                        // Do not let a project's default Open button receive this key.
                        return .handled
                    }
                    .accessibilityLabel("Buscar proyectos o sesiones")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Borrar búsqueda")
                    .accessibilityLabel("Borrar búsqueda")
                } else {
                    Text("⌘F")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(searchFocused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.07), lineWidth: 1)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: searchFocused)

            statusFilterBar
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Botones para filtrar por estado (con su número de proyectos). Pulsar el activo
    /// vuelve a «Todos».
    private var statusFilterBar: some View {
        let counts = statusCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProjectStatusFilter.allCases) { option in
                    let isOn = statusFilter == option
                    Button {
                        statusFilter = (isOn && option != .all) ? .all : option
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: option.systemImage)
                            Text(option.title)
                            Text("\(counts[option] ?? 0)")
                                .monospacedDigit()
                                .foregroundStyle(isOn ? Color.white.opacity(0.8) : Color.secondary)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(
                            isOn ? Color.accentColor : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .help(option.help)
                    .accessibilityLabel("\(option.title), \(counts[option] ?? 0)")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    /// Número de proyectos (y sesiones sueltas) por filtro, en los servidores cargados.
    private var statusCounts: [ProjectStatusFilter: Int] {
        var statuses: [ProjectStatus] = []
        for server in servers {
            guard let vm = vms[server.id], case .loaded = vm.state else { continue }
            let listing = vm.projectListing
            statuses += listing.entries.map { terminalStore.status(of: $0, serverID: server.id) }
            statuses += listing.looseSessions.map { terminalStore.status(of: $0, serverID: server.id) }
        }
        return Dictionary(uniqueKeysWithValues: ProjectStatusFilter.allCases.map { option in
            (option, statuses.filter(option.includes).count)
        })
    }

    /// Mirrors the rendered server/group order and skips collapsed groups, so Return
    /// never selects an item that the list is currently hiding.
    private var firstVisibleSearchResult: SessionHandle? {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let collapsed = CollapsedSessionGroups.shared
        func matches(_ value: String) -> Bool {
            query.isEmpty || value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        for server in servers {
            guard let vm = vms[server.id], case .loaded = vm.state else { continue }
            let listing = vm.projectListing
            let entries = listing.entries.filter {
                (matches($0.project.sessionName) || matches($0.project.path))
                    && statusFilter.includes(terminalStore.status(of: $0, serverID: server.id))
            }
            let loose = listing.looseSessions.filter {
                matches($0.name) && statusFilter.includes(terminalStore.status(of: $0, serverID: server.id))
            }
            let groups = ProjectListing.groups(entries)
            let showHeaders = groups.count > 1 || !loose.isEmpty
                || (groups.first.map { $0.name != SessionGrouping.ungroupedName } ?? false)
            for group in groups {
                let isCollapsed = showHeaders && searchText.isEmpty && statusFilter == .all
                    && collapsed.isCollapsed(serverID: server.id, group: group.name)
                if !isCollapsed, let entry = group.entries.first {
                    return SessionHandle(serverID: server.id, sessionID: entry.project.sessionName)
                }
            }
            let looseIsCollapsed = searchText.isEmpty && statusFilter == .all
                && collapsed.isCollapsed(serverID: server.id, group: "Sesiones sueltas")
            if !looseIsCollapsed, let session = loose.first {
                return SessionHandle(serverID: server.id, sessionID: session.id)
            }
        }
        return nil
    }

    private var workspaceFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow")
            Text("Selecciona para abrir · Clic derecho para más")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let server = activeServer { projectForm = .new(server) }
            } label: {
                Label("Nuevo proyecto", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help(activeServerID != nil
                  ? "Crear un proyecto en \(activeServer?.name ?? "el servidor seleccionado") (⌘N)"
                  : "Selecciona un servidor en la barra lateral")
            .disabled(activeVM?.isWorking ?? true)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { presentBroadcast(preselecting: selection.map { [$0] } ?? []) } label: {
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
            .help(activeServer.map { "CPU, memoria y disco de \($0.name) (⌥⌘I)" }
                  ?? "Selecciona un servidor en la barra lateral")
            .disabled(activeVM == nil)
            .popover(isPresented: $isShowingResources, arrowEdge: .bottom) {
                if let server = activeServer, let vm = activeVM {
                    ServerResourcesView(serverName: server.name, service: vm.service)
                        .id(server.id)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        for vm in vms.values { group.addTask { await vm.load() } }
                    }
                }
            } label: {
                Label("Refrescar todo", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Volver a consultar las sesiones de todos los servidores (⌘R)")
        }
    }

    /// Primer VM con un error de operación pendiente (para el mensaje de la alerta).
    private var vmWithError: SessionsViewModel? {
        servers.compactMap { vms[$0.id] }.first { $0.operationError != nil }
    }

    /// Binding de presentación de la alerta: visible si algún VM tiene error; al
    /// descartar, limpia el error de todos para que no reaparezca.
    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { servers.contains { vms[$0.id]?.operationError != nil } },
            set: { presented in
                if !presented {
                    for server in servers { vms[server.id]?.operationError = nil }
                }
            }
        )
    }

    private var activeServer: Server? {
        guard let id = activeServerID else { return nil }
        return servers.first { $0.id == id }
    }

    private var activeVM: SessionsViewModel? {
        guard let id = activeServerID else { return nil }
        return vms[id]
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

    @ViewBuilder
    private func serverHeader(_ server: Server) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "server.rack")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(server.name)
                .font(.system(size: 12, weight: .semibold))
                .textCase(nil)
                .foregroundStyle(.primary)
            if let vm = vms[server.id], vm.isWorking {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let vm = vms[server.id], case .loaded = vm.state {
                serverMenu(server, vm: vm)
            }
        }
        .padding(.vertical, 5)
    }

    /// Acciones de proyectos del servidor (crear, importar, liberar memoria).
    private func serverMenu(_ server: Server, vm: SessionsViewModel) -> some View {
        let background = backgroundProjects(of: server, vm: vm)
        let looseCount = vm.projectListing.looseSessions.count
        return Menu {
            Button("Nuevo proyecto…") { projectForm = .new(server) }
            Button("Importar sesiones como proyectos…") { importServer = server }
                .disabled(looseCount == 0)
            Divider()
            Button("Detener proyectos en segundo plano (\(background.count))…") {
                projectConfirmation = .stopBackground(server, background)
            }
            .disabled(background.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Acciones de proyectos en \(server.name)")
    }

    /// Proyectos que corren sin estar abiertos en ningún terminal (ni de Argos ni de
    /// otro cliente): siguen consumiendo memoria sin que nadie los mire.
    private func backgroundProjects(of server: Server, vm: SessionsViewModel) -> [Project] {
        vm.projectListing.entries.compactMap { entry in
            guard let session = entry.session else { return nil }
            let handle = SessionHandle(serverID: server.id, sessionID: session.name)
            let state = terminalStore.connectionState(for: handle, isAttached: session.isAttached)
            return state == .dormant ? entry.project : nil
        }
    }

    private func perform(_ confirmation: ProjectConfirmation) {
        guard let vm = vms[confirmation.server.id] else { return }
        let serverID = confirmation.server.id
        Task {
            do {
                switch confirmation {
                case .stop(_, let project):
                    // Cierra antes el terminal (para que no muestre una sesión muerta) y sus
                    // agentes de Claude (cada uno es un proceso que ocupa memoria).
                    let handle = SessionHandle(serverID: serverID, sessionID: project.sessionName)
                    terminalStore.close(handle)
                    agentStore.closeAll(for: handle)
                    try await vm.stopProject(project)
                case .remove(_, let project):
                    try await vm.removeProject(project)
                case .stopBackground(_, let projects):
                    for project in projects {
                        agentStore.closeAll(for: SessionHandle(serverID: serverID, sessionID: project.sessionName))
                    }
                    let failed = await vm.stopSessions(named: projects.map(\.sessionName))
                    if !failed.isEmpty {
                        vm.operationError = "No se pudieron detener: \(failed.joined(separator: ", "))"
                    }
                }
            } catch {
                vm.operationError = error.userMessage
            }
        }
    }

    /// Sondea el estado de Claude Code de todos los servidores cargados (un comando
    /// por servidor cada pocos segundos) y notifica las transiciones relevantes.
    ///
    /// Mientras sondea, la app declara una actividad para que App Nap no la duerma con
    /// la ventana oculta o tapada: si no, los sondeos se espaciaban minutos y los avisos
    /// llegaban tarde o nunca (se perdían estados breves como «esperando»).
    private func pollClaudeActivity() async {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Avisos de Claude Code en las sesiones remotas"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var cycle = 0
        while !Task.isCancelled {
            cycle += 1
            for server in servers {
                guard let vm = vms[server.id] else { continue }
                // Cada pocas vueltas, la lista de sesiones: sin esto no se enteraba de lo
                // creado o cerrado desde el iPhone u otro cliente hasta pulsar ⌘R.
                if cycle.isMultiple(of: Self.sessionListPollCycles) { await vm.refreshSessionsQuietly() }
                let transitions = await vm.refreshClaudeActivity()
                if vm.claudeActivity != .empty {
                    ClaudeActivityNotifier.shared.requestAuthorizationIfNeeded()
                }
                // Si Claude acaba de terminar, el resumen git se relee ya: el aviso dice
                // cuántos archivos cambió y la fila del proyecto se actualiza al momento.
                await vm.refreshGitSummaries(force: transitions.contains { $0.activity == .done })
                let viewing = selection?.serverID == server.id ? selection?.sessionID : nil
                ClaudeActivityNotifier.shared.notify(
                    serverName: server.name, transitions: transitions, viewing: viewing,
                    gitSummary: { vm.gitSummary(forSession: $0) }
                )
                ClaudeActivityNotifier.shared.notifyCI(await vm.pollCIWatches(), serverName: server.name)
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    /// Vueltas del sondeo (3 s cada una) entre lecturas de la lista de sesiones.
    private static let sessionListPollCycles = 3

    private var killDialogBinding: Binding<Bool> {
        Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })
    }
}

// MARK: - Modelo auxiliar para acciones con contexto de servidor

struct SessionAction: Identifiable {
    let server: Server
    let session: TmuxSession
    var id: String { "\(server.id)-\(session.id)" }
}

// MARK: - Fila de sesión

extension SessionConnectionState {
    /// Color del indicador. (`connecting` usa spinner y `dormant` usa luna en su lugar.)
    var color: Color {
        switch self {
        case .live: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .attachedElsewhere: return .blue
        case .dormant: return .secondary.opacity(0.4)
        }
    }

    /// Texto del tooltip.
    var label: String {
        switch self {
        case .live: return "Activa (cargada y conectada)"
        case .connecting: return "Conectando…"
        case .error: return "Error de conexión"
        case .attachedElsewhere: return "Adjunta por otro cliente"
        case .dormant: return "Dormida (no cargada)"
        }
    }
}

struct SessionRow: View {
    let session: TmuxSession
    var state: SessionConnectionState = .dormant
    var displayName: String? = nil
    /// Estado de Claude Code en la sesión (si tiene los hooks de Argos).
    var claude: ClaudeActivity? = nil

    private var title: String { displayName ?? session.name }
    private var isLoaded: Bool { state == .live || state == .connecting }
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLoaded ? "terminal.fill" : "terminal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isLoaded ? Color.accentColor : .secondary)
                .frame(width: 34, height: 34)
                .background(isLoaded ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let claude {
                ClaudeActivityBadge(activity: claude)
            }

            ConnectionIndicator(state: state)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .background(isHovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Etiqueta de VoiceOver: nombre + estado de conexión + nº de ventanas en una sola
    /// frase (la fila se expone como un único elemento, no como piezas sueltas).
    private var accessibilityText: String {
        let windows = "\(session.windowCount) \(session.windowCount == 1 ? "ventana" : "ventanas")"
        let claudeText = claude.map { ", \($0.label)" } ?? ""
        return "\(title), \(state.label), \(windows)\(claudeText)"
    }

    private var subtitle: String {
        let windows = "\(session.windowCount) \(session.windowCount == 1 ? "ventana" : "ventanas")"
        let age = session.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(windows) · \(age)"
    }
}

/// Indicador del estado de conexión de una sesión. Cada estado usa una FORMA distinta
/// además del color, para que sea distinguible sin depender del color (daltonismo):
/// viva = punto, error = exclamación, adjunta-por-otro = persona, conectando = spinner,
/// dormida = luna.
struct ConnectionIndicator: View {
    let state: SessionConnectionState

    var body: some View {
        Group {
            switch state {
            case .connecting:
                ProgressView().controlSize(.mini)
            case .dormant:
                Image(systemName: "moon.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.7))
            case .live:
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(state.color)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(state.color)
            case .attachedElsewhere:
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(state.color)
            }
        }
        .frame(width: 14, height: 14)
        .help(state.label)
        .accessibilityHidden(true)
    }
}

// MARK: - Estados vacíos / error (para compatibilidad con ErrorStateView)

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "Sin sesiones",
            systemImage: "moon.zzz",
            description: Text("No hay sesiones tmux activas en el servidor.")
        )
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No se pudo conectar", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Reintentar", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Fila de sesión") {
    List(TmuxSession.samples) { SessionRow(session: $0) }
        .frame(width: 320, height: 320)
}

#Preview("Vacío") {
    EmptyStateView().frame(width: 520, height: 320)
}

#Preview("Error") {
    ErrorStateView(message: "No se pudo conectar a 100.86.237.26:2222.") {}
        .frame(width: 520, height: 320)
}
#endif
