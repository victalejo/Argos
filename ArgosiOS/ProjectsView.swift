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
    /// En iPad el detalle va en otra columna: la selección la gestiona el padre. En
    /// iPhone (`nil`) se navega dentro de la pila.
    var selection: Binding<ProjectTarget?>?
    @Environment(ServerHub.self) private var hub
    @Environment(\.scenePhase) private var scenePhase

    /// Proyecto/sesión abierto (navegación en iPhone).
    @State private var pushed: ProjectTarget?
    @State private var busyProject: Project.ID?
    @State private var sessionPrompt: SessionPrompt?
    @State private var promptText = ""
    @State private var pendingKill: TmuxSession?
    @State private var errorMessage: String?
    @State private var editingServer: ServerFormView.Mode?
    @State private var scanningQR = false
    @State private var projectForm: ProjectFormMode?
    @State private var worktreesProject: Project?
    @State private var pendingRemoval: Project?

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
            .navigationDestination(item: $pushed) { target in
                ProjectScreen(server: currentServer, target: target)
            }
            .toolbar {
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
                    .disabled(viewModel.state.isBusy || needsKey)
                }
            }
            .task { if !needsKey, case .idle = viewModel.state { await viewModel.load() } }
            .refreshable {
                await viewModel.load()
                await viewModel.refreshGitSummaries(force: true)
            }
            .task { await pollGitSummaries() }
            .onChange(of: scenePhase) { _, phase in
                // Al volver de segundo plano la lista puede estar desfasada (y la conexión
                // SSH, muerta): se recarga, lo que también reconecta.
                if phase == .active, !needsKey, !viewModel.state.isBusy { Task { await viewModel.load() } }
            }
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
            .alert("Algo salió mal", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? viewModel.operationError ?? "")
            }
    }

    // MARK: - Contenido según el estado

    /// Guardar o recibir una clave reinicia la conexión: reintentar con ella.
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
            Button("Importar archivo de clave", systemImage: "key") { editingServer = .edit(currentServer) }
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
                Button("Reintentar") { Task { await viewModel.load() } }
            }
        case .loaded:
            projectList
        }
    }

    private var projectList: some View {
        let listing = viewModel.projectListing
        return List {
            if let projectsError = viewModel.projectsError {
                Label(projectsError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            ForEach(ProjectListing.groups(listing.entries)) { group in
                Section(group.name) {
                    ForEach(group.entries) { entry in
                        projectRow(entry)
                    }
                }
            }
            if !listing.looseSessions.isEmpty {
                Section("Sesiones sin proyecto") {
                    ForEach(listing.looseSessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .overlay {
            if listing.entries.isEmpty && listing.looseSessions.isEmpty {
                ContentUnavailableView {
                    Label("Sin proyectos ni sesiones", systemImage: "terminal")
                } description: {
                    Text("Crea un proyecto o una sesión con «+». Los proyectos que añadas desde Argos en el Mac también aparecen aquí.")
                }
            }
        }
    }

    /// Resumen git de los proyectos (insignia ✎/↑/↓) mientras la lista está visible.
    /// El modelo espacia las lecturas (`gitSummaryInterval`); este bucle solo comprueba
    /// a menudo para que la primera llegue en cuanto termina la carga.
    private func pollGitSummaries() async {
        while !Task.isCancelled {
            await viewModel.refreshGitSummaries()
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
                    Text(session.windowCount == 1 ? "1 ventana" : "\(session.windowCount) ventanas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        guard let session = entry.session else { return "Detenido · \(entry.project.path)" }
        let windows = session.windowCount == 1 ? "1 ventana" : "\(session.windowCount) ventanas"
        return "\(windows) · \(entry.project.path)"
    }

    // MARK: - Acciones

    private func open(_ entry: ProjectEntry) {
        if entry.isRunning {
            show(entry.project)
            return
        }
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
        if let selection { selection.wrappedValue = target } else { pushed = target }
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
        if case .rename = sessionPrompt { return "Renombrar sesión" }
        return "Nueva sesión"
    }

    private var promptAction: String {
        if case .rename = sessionPrompt { return "Renombrar" }
        return "Crear"
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
