//
//  SessionsColumn.swift
//  Argos
//
//  Columna central: sesiones tmux de TODOS los servidores configurados,
//  agrupadas por servidor. Cada sección muestra su estado de conexión propio.
//

import AppKit
import SwiftUI

struct SessionsColumn: View {
    let servers: [Server]
    let vms: [Server.ID: SessionsViewModel]
    /// Pool de terminales en vivo (estado de cada sesión).
    let terminalStore: TerminalSessionStore
    /// Servidor activo en la sidebar (para "Nueva sesión").
    let activeServerID: Server.ID?
    @Binding var selection: SessionHandle?

    @State private var isShowingCreateSheet = false
    @State private var renameTarget: SessionAction?
    @State private var killTarget: SessionAction?
    @State private var searchText = ""
    @State private var isShowingBroadcast = false
    @State private var broadcastPreselect: Set<SessionHandle> = []

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
                            onBroadcast: { presentBroadcast(preselecting: [$0]) }
                        )
                    }
                } header: {
                    serverHeader(server)
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Buscar sesión")
        .navigationTitle("Sesiones tmux")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isShowingCreateSheet) {
            if let vm = activeVM {
                SessionNameSheet(mode: .create) { name in
                    try await vm.createSession(named: name)
                }
            }
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
            Button { isShowingCreateSheet = true } label: {
                Label("Nueva sesión", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help(activeServerID != nil
                  ? "Crear una nueva sesión en \(activeServer?.name ?? "el servidor seleccionado") (⌘N)"
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
        }
    }

    private var killDialogBinding: Binding<Bool> {
        Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })
    }
}

// MARK: - Sección de sesiones de un servidor

private struct ServerSessionsSection: View {
    let server: Server
    let vm: SessionsViewModel
    let terminalStore: TerminalSessionStore
    let filter: String
    @Binding var renameTarget: SessionAction?
    @Binding var killTarget: SessionAction?
    let onBroadcast: (SessionHandle) -> Void

    var body: some View {
        switch vm.state {
        case .idle:
            // Arranque perezoso: este servidor aún no se ha cargado (no es el seleccionado).
            // Ofrecemos conectar bajo demanda en vez de mostrar un spinner engañoso.
            Button {
                Task { await vm.load() }
            } label: {
                Label("Sin cargar — pulsa para conectar", systemImage: "powerplug")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .selectionDisabled()
        case .verifying:
            loadingRow("Verificando tmux…")
        case .installing:
            loadingRow("Instalando tmux…")
        case .configuring:
            loadingRow("Configurando tmux…")
        case .loading:
            loadingRow("Listando sesiones…")

        case .tmuxMissing:
            VStack(alignment: .leading, spacing: 6) {
                Label("tmux no está instalado", systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(Self.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        Self.copyToClipboard(Self.installCommand)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copiar el comando de instalación")
                    Spacer()
                    Button("Reintentar") { Task { await vm.load() } }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)

        case .hostKeyChanged(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("La identidad del servidor cambió", systemImage: "exclamationmark.shield.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    // Resuelve el caso legítimo (reinstalación del servidor): olvida la
                    // huella ANCLADA y reintenta, re-confiando en la nueva. La acción vive
                    // aquí (junto al error) en vez de en el menú contextual de otra columna.
                    Button("Olvidar host key y reintentar") {
                        TOFUHostKeyValidator.forget(host: server.host, port: server.port)
                        Task { await vm.load() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            .padding(.vertical, 2)

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Reintentar") { Task { await vm.load() } }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }

        case .loaded(let sessions) where sessions.isEmpty:
            Label("Sin sesiones activas", systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .loaded(let sessions):
            let filtered = Self.matching(sessions, filter: filter)
            if filtered.isEmpty {
                Label("Sin coincidencias", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Agrupa por prefijo ("grupo/nombre"). Solo muestra encabezados de grupo
                // cuando hay grupos reales (si todo cae en "General", no añade ruido).
                let groups = SessionGrouping.groups(from: filtered)
                let showGroupHeaders = groups.count > 1
                    || (groups.first.map { $0.name != SessionGrouping.ungroupedName } ?? false)
                ForEach(groups) { group in
                    if showGroupHeaders {
                        groupHeader(group.name)
                    }
                    ForEach(group.sessions) { session in
                        sessionRow(
                            session,
                            displayName: showGroupHeaders ? SessionGrouping.shortName(for: session.name) : nil
                        )
                    }
                }
            }
        }
    }

    /// Encabezado de un grupo de sesiones. No es seleccionable (no es una sesión).
    @ViewBuilder
    private func groupHeader(_ name: String) -> some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 4)
            .selectionDisabled()
    }

    /// Una fila de sesión con su menú contextual. `displayName` muestra el nombre corto
    /// dentro de un grupo (el id real sigue siendo el nombre completo).
    @ViewBuilder
    private func sessionRow(_ session: TmuxSession, displayName: String?) -> some View {
        let handle = SessionHandle(serverID: server.id, sessionID: session.id)
        let state = terminalStore.connectionState(for: handle, isAttached: session.isAttached)
        SessionRow(session: session, state: state, displayName: displayName)
            .tag(handle)
            .contextMenu {
                if state == .live || state == .connecting || state == .error {
                    Button("Desconectar (dormir)") {
                        terminalStore.close(handle)
                    }
                    Divider()
                }
                Button("Enviar comando…") { onBroadcast(handle) }
                Button("Renombrar…") {
                    renameTarget = SessionAction(server: server, session: session)
                }
                Button("Matar…", role: .destructive) {
                    killTarget = SessionAction(server: server, session: session)
                }
            }
    }

    /// Comando manual de instalación de tmux (Debian/Ubuntu; el bootstrap usa apt).
    private static let installCommand = "sudo apt install -y tmux"

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Filtra por subcadena (case/diacritic-insensitive). Filtro vacío = todas.
    private static func matching(_ sessions: [TmuxSession], filter: String) -> [TmuxSession] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    @ViewBuilder
    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
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

            statusIndicator
                .frame(width: 14, height: 14)
                .help(state.label)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Etiqueta de VoiceOver: nombre + estado de conexión + nº de ventanas en una sola
    /// frase (la fila se expone como un único elemento, no como piezas sueltas).
    private var accessibilityText: String {
        let windows = "\(session.windowCount) \(session.windowCount == 1 ? "ventana" : "ventanas")"
        return "\(title), \(state.label), \(windows)"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .connecting:
            ProgressView().controlSize(.mini)
        case .dormant:
            // 🌙 dormida
            Image(systemName: "moon.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.7))
        default:
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
        }
    }

    private var subtitle: String {
        let windows = "\(session.windowCount) \(session.windowCount == 1 ? "ventana" : "ventanas")"
        let age = session.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(windows) · \(age)"
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
