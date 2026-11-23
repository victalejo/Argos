//
//  ProjectsView.swift
//  ArgosiOS
//
//  Proyectos y sesiones tmux de un servidor. Los proyectos viven en el servidor
//  (`~/.config/argos/projects.json`), así que son los mismos que ve Argos en el Mac.
//  Tocar un proyecto lo abre (crea su sesión si estaba detenido) en el terminal.
//

import SwiftUI

struct ProjectsView: View {
    let server: Server
    /// Proyecto/sesión abierto en el detalle (lo gestiona `AppNavigation`; en iPhone la
    /// vista dividida colapsada lo muestra encima de la lista).
    @Binding var selection: ProjectTarget?
    /// Pestaña del detalle (para abrir un proyecto desde un aviso o un atajo en la pestaña
    /// pedida). `nil` en vistas que no la controlan.
    var mode: Binding<DetailMode>? = nil
    @Environment(ServerHub.self) private var hub

    @State private var busyProject: Project.ID?
    @State private var sessionPrompt: SessionPrompt?
    @State private var promptText = ""
    @State private var pendingKill: TmuxSession?
    @State private var errorMessage: String?
    /// Abrir un proyecto con la memoria del servidor en estado crítico: a la espera de confirmar.
    @State private var memoryConfirmation: MemoryStartConfirmation?
    @State private var editingServer: ServerFormView.Mode?
    @State private var scanningQR = false
    @State private var projectForm: ProjectFormMode?
    @State private var worktreesProject: Project?
    @State private var pendingRemoval: Project?
    @State private var searchText = ""
    @State private var statusFilter: ProjectStatusFilter = .all
    @State private var collapsedGroups = CollapsedSessionGroups.shared
    @State private var showingResources = false
    @State private var confirmRestore = false
    @State private var isRestoring = false

    private enum SessionPrompt: Identifiable {
        case create
        case rename(TmuxSession)
        var id: String {
            switch self {
            case .create: return "nueva"
            case .rename(let session): return "renombrar-\(session.name)"
            }
        }
    }

    private var viewModel: SessionsViewModel { hub.viewModel(for: currentServer) }
    /// El servidor tal como está guardado ahora (puede haberse editado tras abrir la vista).
    private var currentServer: Server { hub.store.server(withID: server.id) ?? server }
    /// Servidor llegado del Mac por iCloud sin su clave en este dispositivo: no se intenta
    /// conectar (fallaría seguro); se guía a recibirla del Mac.
    private var needsKey: Bool { ImportedKeyStore.needsImport(currentServer) }

    var body: some View {
        content
            .navigationTitle(server.name)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Recursos del servidor", systemImage: "gauge.with.dots.needle.50percent") { showingResources = true }
                        .disabled(needsKey)
                }
                ToolbarItem(placement: .primaryAction) {
                    statusFilterMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Nuevo proyecto", systemImage: "folder.badge.plus") { projectForm = .new }
                        Button("Nueva sesión", systemImage: "terminal") {
                            promptText = ""
                            sessionPrompt = .create
                        }
                    } label: {
                        Label("Nuevo", systemImage: "plus")
                    }
                    .disabled(viewModel.isWorking || needsKey)
                }
            }
            .task { if !needsKey, case .idle = viewModel.state { await viewModel.load() } }
            .refreshable {
                await viewModel.load()
                await viewModel.refreshGitSummaries(force: true)
            }
            .task { await pollGitSummaries() }
            .onChange(of: hub.pendingRoute, initial: true) { _, _ in followPendingRoute() }
            .onChange(of: viewModel.sessions) { _, _ in followPendingRoute() }
            // Atajos, Siri y Spotlight listan los proyectos sin red.
            .onChange(of: viewModel.projects, initial: true) { _, _ in updateShortcutIndex() }
            .onChange(of: isLoaded) { _, _ in updateShortcutIndex() }
            // La vuelta de segundo plano la gestiona `ServerHub.didBecomeActive`: sondea la
            // conexión y refresca sin vaciar la lista (antes cualquier paso de inactivo a
            // activo, como abrir el Centro de control, la cambiaba por «Conectando…»).
            .alert(promptTitle, isPresented: promptBinding) {
                TextField("Nombre", text: $promptText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancelar", role: .cancel) {}
                Button(promptAction) { submitPrompt() }
            } message: {
                Text("Usa «grupo/nombre» para agruparla. Sin «:» ni «.».")
            }
            .confirmationDialog(
                "¿Cerrar la sesión «\(pendingKill?.name ?? "")»?",
                isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
                titleVisibility: .visible
            ) {
                Button("Cerrar sesión", role: .destructive) {
                    if let session = pendingKill { kill(session) }
                    pendingKill = nil
                }
            } message: {
                Text("Se terminan los procesos que corren en ella (kill-session).")
            }
            .sheet(item: $projectForm) { mode in
                ProjectFormView(mode: mode, vm: viewModel, serverName: currentServer.name)
            }
            .sheet(isPresented: $showingResources) {
                ServerResourcesScreen(serverName: currentServer.name, service: viewModel.service)
            }
            .sheet(item: $worktreesProject) { project in
                WorktreesView(project: project, vm: viewModel)
            }
            .confirmationDialog(
                "¿Quitar «\(pendingRemoval?.name ?? "")» de Argos?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { project in
                Button("Quitar de Argos", role: .destructive) { remove(project) }
            } message: { _ in
                Text("Sus archivos del servidor no se tocan. Si su sesión está en marcha, sigue abierta como sesión suelta.")
            }
            .sheet(item: $editingServer, onDismiss: reloadAfterKeyChange) { mode in
                ServerFormView(mode: mode)
            }
            .sheet(isPresented: $scanningQR, onDismiss: reloadAfterKeyChange) {
                ImportServerSheet()
            }
            .confirmationDialog(
                "¿Restaurar la copia anterior de los proyectos?",
                isPresented: $confirmRestore,
                titleVisibility: .visible
            ) {
                Button("Restaurar copia anterior") { restoreBackup() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(String(localized: "Se recupera projects.json.argos-backup de \(currentServer.name). El archivo dañado se guarda aparte (projects.json.argos-damaged) por si lo necesitas; los cambios hechos después de esa copia se pierden."))
            }
            .alert("Algo salió mal", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? viewModel.operationError ?? "")
            }
    }

    // MARK: - Contenido según el estado

    /// Guardar o recibir una clave reinicia la conexión: reintentar con ella.
    /// Con las credenciales rechazadas, reintentar no sirve: lo primero es poder corregirlas.
    @ViewBuilder
    private func failedActions(message: String) -> some View {
        if message == SSHErrorMessage.authenticationRejected {
            Button("Editar servidor", systemImage: "pencil") { editingServer = .edit(currentServer) }
                .buttonStyle(.borderedProminent)
        }
        Button("Reintentar") { Task { await viewModel.load() } }
    }

    private func reloadAfterKeyChange() {
        guard !needsKey else { return }
        Task { await hub.viewModel(for: currentServer).load() }
    }

    private var missingKey: some View {
        ContentUnavailableView {
            Label("Falta la clave en este dispositivo", systemImage: "key.slash")
        } description: {
            Text("«\(currentServer.name)» llegó de tu Mac por iCloud, pero las claves SSH no viajan. En el Mac, abre el menú del servidor → «Enviar al iPhone…» y escanea el código: se crea una clave solo para este dispositivo.")
        } actions: {
            Button("Escanear QR del Mac", systemImage: "qrcode.viewfinder") { scanningQR = true }
                .buttonStyle(.borderedProminent)
            Button("Importar, pegar o crear una clave", systemImage: "key") { editingServer = .edit(currentServer) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if needsKey {
            missingKey
        } else {
            connectionContent
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        switch viewModel.state {
        case .idle, .verifying, .loading:
            ProgressView("Conectando con \(server.name)…")
        case .installing:
            ProgressView("Instalando tmux en el servidor…")
        case .configuring:
            ProgressView("Configurando tmux…")
        case .tmuxMissing:
            ContentUnavailableView {
                Label("Falta tmux", systemImage: "shippingbox")
            } description: {
                Text("Instálalo en el servidor (por ejemplo, «sudo apt install tmux») y vuelve a intentarlo.")
            } actions: {
                Button("Reintentar") { Task { await viewModel.load() } }
            }
        case .hostKeyChanged(let message):
            ContentUnavailableView {
                Label("La huella del servidor cambió", systemImage: "exclamationmark.shield")
            } description: {
                Text(message)
            } actions: {
                Button("Confiar en la nueva huella", role: .destructive) {
                    hub.forgetHostKey(of: server)
                    Task { await hub.viewModel(for: currentServer).load() }
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudo conectar", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                failedActions(message: message)
            }
        case .loaded:
            projectList
        }
    }

    private var projectList: some View {
        let visible = visibleListing
        return List {
            ServerTipsSection(server: currentServer, viewModel: viewModel)
            if let pressure = viewModel.memoryPressure, pressure.level > .normal {
                // El diálogo cuelga del aviso: solo se confirma en nivel crítico, con el aviso a la vista.
                MemoryPressureBanner(pressure: pressure)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .memoryPressureConfirmation($memoryConfirmation)
            }
            if let projectsError = viewModel.projectsError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(projectsError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                    if projectsError == ProjectError.invalidFile.errorDescription {
                        Button {
                            confirmRestore = true
                        } label: {
                            HStack {
                                Label("Restaurar copia anterior", systemImage: "clock.arrow.circlepath")
                                if isRestoring { ProgressView() }
                            }
                        }
                        .disabled(isRestoring)
                    }
                }
            }
            ForEach(visible.groups) { group in
                Section {
                    ForEach(group.visibleEntries) { entry in
                        projectRow(entry)
                    }
                } header: {
                    if visible.showsGroupHeaders {
                        groupHeader(
                            name: group.name, count: group.entries.count, sessions: group.sessionNames,
                            isCollapsed: group.isCollapsed, canCollapse: !visible.isFiltering
                        )
                    }
                }
            }
            if !visible.looseSessions.isEmpty {
                Section {
                    ForEach(visible.visibleLooseSessions) { session in
                        sessionRow(session)
                    }
                } header: {
                    groupHeader(
                        name: VisibleProjectListing.looseGroupName, count: visible.looseSessions.count,
                        sessions: visible.looseSessions.map(\.name),
                        isCollapsed: visible.isLooseCollapsed, canCollapse: !visible.isFiltering
                    )
                }
            }
        }
        .searchable(text: $searchText, prompt: "Buscar proyectos o sesiones")
        .onSubmit(of: .search) {
            guard let name = visibleListing.firstVisibleSessionName else { return }
            if let entry = viewModel.projectListing.entries.first(where: { $0.project.sessionName == name }) {
                open(entry)
            } else {
                show(session: name)
            }
        }
        .overlay {
            if visible.isSourceEmpty {
                ContentUnavailableView {
                    Label("Sin proyectos ni sesiones", systemImage: "terminal")
                } description: {
                    Text("Crea un proyecto o una sesión con «+». Los proyectos que añadas desde Argos en el Mac también aparecen aquí.")
                }
            } else if visible.hasNoMatches {
                ContentUnavailableView {
                    Label("Sin coincidencias", systemImage: "magnifyingglass")
                } description: {
                    Text(statusFilter == .all || !searchText.isEmpty
                         ? "Prueba con otro nombre o carpeta."
                         : "Ningún proyecto «\(statusFilter.title.lowercased())» en este servidor.")
                } actions: {
                    if statusFilter != .all { Button("Ver todos") { statusFilter = .all } }
                }
            }
        }
    }

    // MARK: - Búsqueda, filtro y grupos

    private var visibleListing: VisibleProjectListing {
        let listing = viewModel.projectListing
        let serverID = server.id
        return VisibleProjectListing(
            entries: listing.entries,
            looseSessions: listing.looseSessions,
            query: searchText,
            statusFilter: statusFilter,
            status: status(of:),
            sessionStatus: status(of:),
            isCollapsed: { collapsedGroups.isCollapsed(serverID: serverID, group: $0) }
        )
    }

    /// Estado para el filtro: «abierta» si hay un terminal de Argos en este dispositivo.
    private func status(of entry: ProjectEntry) -> ProjectStatus {
        let connection = entry.session.map { connectionState(sessionName: entry.project.sessionName, isAttached: $0.isAttached) }
        return .of(connection: connection, onMac: entry.project.macCheckout != nil)
    }

    private func status(of session: TmuxSession) -> ProjectStatus {
        .of(connection: connectionState(sessionName: session.name, isAttached: session.isAttached), onMac: false)
    }

    private func connectionState(sessionName: String, isAttached: Bool) -> SessionConnectionState {
        let open = hub.hasTerminal(server: server.id, sessionName: sessionName)
        return .from(status: open ? .connected : nil, isAttached: isAttached)
    }

    private var statusFilterMenu: some View {
        let listing = viewModel.projectListing
        let counts = VisibleProjectListing.statusCounts(
            entries: listing.entries, looseSessions: listing.looseSessions,
            status: status(of:), sessionStatus: status(of:)
        )
        return Menu {
            Picker("Mostrar", selection: $statusFilter) {
                ForEach(ProjectStatusFilter.allCases) { option in
                    Label("\(option.title) (\(counts[option] ?? 0))", systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label("Filtrar", systemImage: statusFilter == .all
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .disabled(needsKey)
    }

    private func groupHeader(name: String, count: Int, sessions: [String], isCollapsed: Bool, canCollapse: Bool) -> some View {
        Button {
            withAnimation { collapsedGroups.toggle(serverID: server.id, group: name) }
        } label: {
            HStack(spacing: 6) {
                if canCollapse {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                Text(VisibleProjectListing.displayName(ofGroup: name))
                Text("\(count)").foregroundStyle(.secondary)
                Spacer()
                // Plegado, la insignia del grupo avisa de lo que hay dentro.
                if isCollapsed, let claude = viewModel.claudeActivity.activity(forSessions: sessions) {
                    ClaudeActivityBadge(activity: claude, size: 12)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canCollapse)
        .accessibilityLabel("Grupo \(VisibleProjectListing.displayName(ofGroup: name)), \(count) elementos")
        .accessibilityValue(canCollapse ? (isCollapsed ? "plegado" : "desplegado") : "")
    }

    /// Resumen git de los proyectos (insignia ✎/↑/↓) mientras la lista está visible.
    /// El modelo espacia las lecturas (`gitSummaryInterval`); este bucle solo comprueba
    /// a menudo para que la primera llegue en cuanto termina la carga.
    private func pollGitSummaries() async {
        while !Task.isCancelled {
            // También la lista: recoge lo creado o cerrado desde el Mac u otro cliente.
            await viewModel.refreshSessionsQuietly()
            await viewModel.refreshGitSummaries()
            await viewModel.refreshMemoryPressure()
            AgentNotifier.shared.postCI(await viewModel.pollCIWatches(), server: currentServer)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func projectRow(_ entry: ProjectEntry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isRunning ? "folder.fill" : "folder")
                    .foregroundStyle(entry.isRunning ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.project.name).font(.body.weight(.medium))
                    Text(subtitle(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let claude = viewModel.claudeActivity.activity(forSession: entry.project.sessionName) {
                    ClaudeActivityBadge(activity: claude, size: 15)
                }
                if let git = viewModel.gitSummary(for: entry.project) {
                    GitSummaryBadge(summary: git)
                }
                if busyProject == entry.id {
                    ProgressView()
                } else if entry.isRunning {
                    Circle().fill(.green).frame(width: 8, height: 8)
                        .accessibilityLabel("En marcha")
                }
            }
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            if let session = entry.session {
                Button("Detener", systemImage: "stop.fill", role: .destructive) { pendingKill = session }
            }
            Button("Editar", systemImage: "pencil") { projectForm = .edit(entry.project) }
                .tint(.indigo)
        }
        .contextMenu {
            Button("Editar proyecto…", systemImage: "pencil") { projectForm = .edit(entry.project) }
            Button("Ramas en paralelo…", systemImage: "arrow.triangle.branch") { worktreesProject = entry.project }
            Divider()
            Button("Quitar de Argos", systemImage: "folder.badge.minus", role: .destructive) {
                pendingRemoval = entry.project
            }
        }
    }

    private func sessionRow(_ session: TmuxSession) -> some View {
        Button {
            show(session: session.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "terminal").foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name).font(.body.weight(.medium))
                    Text("\(session.windowCount) ventanas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let claude = viewModel.claudeActivity.activity(forSession: session.name) {
                    ClaudeActivityBadge(activity: claude, size: 15)
                }
            }
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            Button("Cerrar", systemImage: "xmark", role: .destructive) { pendingKill = session }
            Button("Renombrar", systemImage: "pencil") {
                promptText = session.name
                sessionPrompt = .rename(session)
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button("Convertir en proyecto…", systemImage: "folder.badge.plus") { projectForm = .convert(session) }
        }
    }

    private func subtitle(for entry: ProjectEntry) -> String {
        guard let session = entry.session else { return String(localized: "Detenido · \(entry.project.path)") }
        let windows = String(localized: "\(session.windowCount) ventanas")
        return "\(windows) · \(entry.project.path)"
    }

    // MARK: - Acciones

    private func open(_ entry: ProjectEntry) {
        if entry.isRunning {
            show(entry.project)
            return
        }
        if let pressure = viewModel.memoryPressure, pressure.needsConfirmationToStart {
            memoryConfirmation = MemoryStartConfirmation(pressure: pressure) { start(entry) }
            return
        }
        start(entry)
    }

    private func start(_ entry: ProjectEntry) {
        busyProject = entry.id
        Task {
            defer { busyProject = nil }
            do {
                try await viewModel.openProject(
                    entry.project,
                    defaultStartupCommand: ProjectSettings.shared.defaultStartupCommand
                )
                show(entry.project)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func show(_ project: Project) {
        open(ProjectTarget(sessionName: project.sessionName, title: project.name, path: project.path))
    }

    private func show(session name: String) {
        open(ProjectTarget(sessionName: name, title: name, path: nil))
    }

    private func open(_ target: ProjectTarget) {
        selection = target
        if let path = target.path {
            ProjectShortcutIndex.markUsed(CachedProject.identifier(serverID: server.id, path: path))
        }
    }

    /// Una lista vacía solo cuenta si la carga terminó bien: con `projects.json` dañado o
    /// sin conexión se conserva lo último conocido.
    private func updateShortcutIndex() {
        let projects = viewModel.projects
        guard !projects.isEmpty || (isLoaded && viewModel.projectsError == nil) else { return }
        ProjectShortcutIndex.update(serverID: server.id, projects: projects)
    }

    private var isLoaded: Bool {
        if case .loaded = viewModel.state { return true }
        return false
    }

    /// Notificación tocada (o atajo, Spotlight…): abre su proyecto o sesión (y su ventana,
    /// pestaña o agente) en cuanto la lista está cargada.
    private func followPendingRoute() {
        guard let route = hub.pendingRoute, route.serverID == server.id else { return }
        guard route.session != nil || route.projectPath != nil else {
            hub.pendingRoute = nil   // el aviso solo señalaba el servidor
            return
        }
        guard isLoaded else { return }   // se reintenta al cargar
        hub.pendingRoute = nil
        if let path = route.projectPath, followProject(route, path: path) { return }
        guard let session = route.session else { return }
        if let entry = viewModel.projectListing.entries.first(where: { $0.project.sessionName == session }) {
            show(entry.project)
        } else if viewModel.session(withID: session) != nil {
            show(session: session)
        } else {
            return   // la sesión ya no existe: se queda en la lista
        }
        if let window = route.window {
            let service = viewModel.service
            Task {
                do {
                    try await service.selectWindow(session: session, index: window)
                } catch {
                    Log.terminal.notice("No se pudo ir a la ventana del aviso: \(error.userMessage, privacy: .public)")
                }
            }
        }
    }

    /// Abre el proyecto de la carpeta `path` en la pestaña pedida; con agente, deja su chat
    /// pendiente para que lo abra `AgentsView`. `false` si el proyecto ya no está.
    private func followProject(_ route: NotificationRoute, path: String) -> Bool {
        let folder = ShortcutAgentPlanner.normalized(path)
        let entries = viewModel.projectListing.entries
        guard let entry = entries.first(where: { ShortcutAgentPlanner.normalized($0.project.path) == folder })
            ?? entries.first(where: { $0.project.sessionName == route.session }) else { return false }
        let tab = route.tab ?? .terminal
        if tab == .terminal, !entry.isRunning {
            open(entry)   // el terminal necesita su sesión: se arranca como al tocarlo
        } else {
            show(entry.project)
        }
        mode?.wrappedValue = tab.detailMode
        if let agentID = route.agentID { hub.pendingAgentID = agentID }
        return true
    }

    private func restoreBackup() {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                try await viewModel.restoreProjectsBackup()
            } catch {
                Log.store.error("Restaurar proyectos: \(error.userMessage, privacy: .private)")
                errorMessage = error.userMessage
            }
        }
    }

    private func remove(_ project: Project) {
        Task {
            do {
                try await viewModel.removeProject(project)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func kill(_ session: TmuxSession) {
        hub.closeTerminal(server: server.id, sessionName: session.name)
        Task { await viewModel.kill(session) }
    }

    private func submitPrompt() {
        guard let prompt = sessionPrompt else { return }
        let name = promptText
        Task {
            do {
                switch prompt {
                case .create:
                    try await viewModel.createSession(named: name)
                    show(session: try SessionNameValidator.validate(name))
                case .rename(let session):
                    hub.closeTerminal(server: server.id, sessionName: session.name)
                    try await viewModel.renameSession(session, to: name)
                }
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private var promptTitle: String {
        if case .rename = sessionPrompt { return String(localized: "Renombrar sesión") }
        return String(localized: "Nueva sesión")
    }

    private var promptAction: String {
        if case .rename = sessionPrompt { return String(localized: "Renombrar") }
        return String(localized: "Crear")
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { sessionPrompt != nil }, set: { if !$0 { sessionPrompt = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil || viewModel.operationError != nil },
            set: { if !$0 { errorMessage = nil; viewModel.operationError = nil } }
        )
    }
}
