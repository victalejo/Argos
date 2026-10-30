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
    @State private var renameTarget: SessionAction?
    @State private var killTarget: SessionAction?
    @State private var searchText = ""
    @State private var isShowingBroadcast = false
    @State private var broadcastPreselect: Set<SessionHandle> = []
    @State private var isShowingResources = false

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
                            renameTarget: $renameTarget,
                            killTarget: $killTarget,
                            projectForm: $projectForm,
                            projectConfirmation: $projectConfirmation,
                            importServer: $importServer,
                            onBroadcast: { presentBroadcast(preselecting: [$0]) }
                        )
                    }
                } header: {
                    serverHeader(server)
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Buscar proyecto")
        .task { await pollClaudeActivity() }
        .navigationTitle("Proyectos")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .toolbar { toolbarContent }
        .sheet(item: $projectForm) { request in
            if let vm = vms[request.server.id] {
                ProjectFormSheet(request: request, vm: vm)
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
            .disabled(activeVM?.state.isBusy ?? true)
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
        HStack(spacing: 6) {
            Text(server.name)
            if let vm = vms[server.id], vm.state.isBusy {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let vm = vms[server.id], case .loaded = vm.state {
                serverMenu(server, vm: vm)
            }
        }
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
    private func pollClaudeActivity() async {
        while !Task.isCancelled {
            for server in servers {
                guard let vm = vms[server.id] else { continue }
                let transitions = await vm.refreshClaudeActivity()
                if vm.claudeActivity != .empty {
                    ClaudeActivityNotifier.shared.requestAuthorizationIfNeeded()
                }
                ClaudeActivityNotifier.shared.notify(serverName: server.name, transitions: transitions)
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLoaded ? "terminal.fill" : "terminal")
                .font(.body)
                .foregroundStyle(isLoaded ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
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
        .padding(.vertical, 3)
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
