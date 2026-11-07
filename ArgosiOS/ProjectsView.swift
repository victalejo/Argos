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
    @Environment(ServerHub.self) private var hub
    @Environment(\.scenePhase) private var scenePhase

    /// Sesión abierta en el terminal (navegación).
    @State private var openSession: OpenSession?
    @State private var busyProject: Project.ID?
    @State private var sessionPrompt: SessionPrompt?
    @State private var promptText = ""
    @State private var pendingKill: TmuxSession?
    @State private var errorMessage: String?

    struct OpenSession: Hashable, Identifiable {
        let name: String
        var id: String { name }
    }

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

    private var viewModel: SessionsViewModel { hub.viewModel(for: server) }

    var body: some View {
        content
            .navigationTitle(server.name)
            .navigationDestination(item: $openSession) { session in
                TerminalScreen(server: server, sessionName: session.name)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Nueva sesión", systemImage: "plus") {
                        promptText = ""
                        sessionPrompt = .create
                    }
                    .disabled(viewModel.state.isBusy)
                }
            }
            .task { if case .idle = viewModel.state { await viewModel.load() } }
            .refreshable { await viewModel.load() }
            .onChange(of: scenePhase) { _, phase in
                // Al volver de segundo plano la lista puede estar desfasada (y la conexión
                // SSH, muerta): se recarga, lo que también reconecta.
                if phase == .active, !viewModel.state.isBusy { Task { await viewModel.load() } }
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
            .alert("Algo salió mal", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? viewModel.operationError ?? "")
            }
    }

    // MARK: - Contenido según el estado

    @ViewBuilder
    private var content: some View {
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
                    Task { await hub.viewModel(for: server).load() }
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
                    Text("Crea una sesión con «+». Los proyectos que añadas desde Argos en el Mac aparecen aquí.")
                }
            }
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
        }
    }

    private func sessionRow(_ session: TmuxSession) -> some View {
        Button {
            openSession = OpenSession(name: session.name)
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
    }

    private func subtitle(for entry: ProjectEntry) -> String {
        guard let session = entry.session else { return "Detenido · \(entry.project.path)" }
        let windows = session.windowCount == 1 ? "1 ventana" : "\(session.windowCount) ventanas"
        return "\(windows) · \(entry.project.path)"
    }

    // MARK: - Acciones

    private func open(_ entry: ProjectEntry) {
        if entry.isRunning {
            openSession = OpenSession(name: entry.project.sessionName)
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
                openSession = OpenSession(name: entry.project.sessionName)
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
                    openSession = OpenSession(name: try SessionNameValidator.validate(name))
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
