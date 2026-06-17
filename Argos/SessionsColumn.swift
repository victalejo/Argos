//
//  SessionsColumn.swift
//  Argos
//
//  Columna central: sesiones tmux de TODOS los servidores configurados,
//  agrupadas por servidor. Cada sección muestra su estado de conexión propio.
//

import SwiftUI

struct SessionsColumn: View {
    let servers: [Server]
    let vms: [Server.ID: SessionsViewModel]
    /// Servidor activo en la sidebar (para "Nueva sesión").
    let activeServerID: Server.ID?
    @Binding var selection: SessionHandle?

    @State private var isShowingCreateSheet = false
    @State private var renameTarget: SessionAction?
    @State private var killTarget: SessionAction?

    var body: some View {
        List(selection: $selection) {
            ForEach(servers) { server in
                Section {
                    if let vm = vms[server.id] {
                        ServerSessionsSection(
                            server: server,
                            vm: vm,
                            renameTarget: $renameTarget,
                            killTarget: $killTarget
                        )
                    }
                } header: {
                    serverHeader(server)
                }
            }
        }
        .navigationTitle("Sesiones tmux")
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isShowingCreateSheet = true } label: {
                    Label("Nueva sesión", systemImage: "plus")
                }
                .help(activeServerID != nil
                      ? "Crear una nueva sesión en \(activeServer?.name ?? "el servidor seleccionado")"
                      : "Selecciona un servidor en la barra lateral")
                .disabled(activeVM?.state.isBusy ?? true)
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
                .help("Volver a consultar las sesiones de todos los servidores")
            }
        }
        .sheet(isPresented: $isShowingCreateSheet) {
            if let vm = activeVM {
                SessionNameSheet(mode: .create) { name in
                    try await vm.createSession(named: name)
                }
            }
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
    }

    private var activeServer: Server? {
        guard let id = activeServerID else { return nil }
        return servers.first { $0.id == id }
    }

    private var activeVM: SessionsViewModel? {
        guard let id = activeServerID else { return nil }
        return vms[id]
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
    @Binding var renameTarget: SessionAction?
    @Binding var killTarget: SessionAction?

    var body: some View {
        switch vm.state {
        case .idle:
            loadingRow("Conectando…")
        case .verifying:
            loadingRow("Verificando tmux…")
        case .installing:
            loadingRow("Instalando tmux…")
        case .configuring:
            loadingRow("Configurando tmux…")
        case .loading:
            loadingRow("Listando sesiones…")

        case .tmuxMissing:
            Label("tmux no instalado — instálalo manualmente", systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)

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
            ForEach(sessions) { session in
                SessionRow(session: session)
                    .tag(SessionHandle(serverID: server.id, sessionID: session.id))
                    .contextMenu {
                        Button("Renombrar…") {
                            renameTarget = SessionAction(server: server, session: session)
                        }
                        Button("Matar…", role: .destructive) {
                            killTarget = SessionAction(server: server, session: session)
                        }
                    }
            }
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

struct SessionRow: View {
    let session: TmuxSession
    var displayName: String? = nil

    private var title: String { displayName ?? session.name }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.isAttached ? "terminal.fill" : "terminal")
                .font(.body)
                .foregroundStyle(session.isAttached ? Color.accentColor : .secondary)
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

            Circle()
                .fill(session.isAttached ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 3)
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
