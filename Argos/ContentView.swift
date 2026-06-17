//
//  ContentView.swift
//  Argos
//
//  Raíz de la app: NavigationSplitView de 3 columnas —
//  servidores (multi-servidor) → sesiones tmux → terminal en vivo.
//

import SwiftUI

struct ContentView: View {
    @State private var store = ServerStore()
    @State private var selectedServerID: Server.ID?
    @State private var selectedSession: TmuxSession.ID?

    /// ViewModel del servidor activo; se reconstruye al cambiar de servidor.
    @State private var sessionsVM: SessionsViewModel?
    /// Se incrementa para forzar la reconstrucción del servicio (p. ej. al editar
    /// el servidor activo): cambiar el id del `.task` sin depender de selectedServerID.
    @State private var reloadToken = 0

    // Gestión de servidores
    @State private var serverFormMode: ServerFormSheet.Mode?
    @State private var serverToDelete: Server?

    var body: some View {
        NavigationSplitView {
            serverSidebar
        } content: {
            sessionsContent
        } detail: {
            terminalDetail
        }
        .frame(minWidth: 980, minHeight: 560)
        .onAppear {
            if selectedServerID == nil { selectedServerID = store.servers.first?.id }
        }
        // Reconstruye el servicio + ViewModel y lista sesiones al cambiar de servidor
        // (o al editar el activo, vía reloadToken).
        .task(id: "\(selectedServerID?.uuidString ?? "none")#\(reloadToken)") {
            selectedSession = nil
            guard let server = store.server(withID: selectedServerID) else {
                sessionsVM = nil
                return
            }
            let vm = SessionsViewModel(service: Self.makeService(for: server))
            sessionsVM = vm
            await vm.load()
        }
        .sheet(item: $serverFormMode) { mode in
            ServerFormSheet(mode: mode) { server, passphrase in
                save(server, passphrase: passphrase)
            }
        }
        .confirmationDialog(
            serverToDelete.map { "¿Eliminar el servidor '\($0.name)'?" } ?? "",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: serverToDelete
        ) { server in
            Button("Eliminar", role: .destructive) { delete(server) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Se borrará su configuración y su passphrase del Keychain. No afecta al servidor remoto.")
        }
    }

    // MARK: - Columna 1: servidores

    private var serverSidebar: some View {
        List(selection: $selectedServerID) {
            Section("Servidores") {
                ForEach(store.servers) { server in
                    ServerRow(server: server)
                        .tag(server.id)
                        .contextMenu {
                            Button("Editar…") { serverFormMode = .edit(server) }
                            Button("Olvidar host key") {
                                TOFUHostKeyValidator.forget(host: server.host, port: server.port)
                            }
                            Button("Eliminar…", role: .destructive) { serverToDelete = server }
                        }
                }
            }
        }
        .navigationTitle("Argos")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { serverFormMode = .add } label: {
                    Label("Añadir servidor", systemImage: "plus")
                }
                .help("Añadir un servidor SSH")
            }
        }
    }

    // MARK: - Columna 2: sesiones

    @ViewBuilder
    private var sessionsContent: some View {
        if let sessionsVM {
            SessionsColumn(viewModel: sessionsVM, selection: $selectedSession)
        } else {
            ContentUnavailableView {
                Label("Sin servidor", systemImage: "server.rack")
            } description: {
                Text("Selecciona o añade un servidor para ver sus sesiones tmux.")
            } actions: {
                Button("Añadir servidor") { serverFormMode = .add }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Columna 3: terminal

    @ViewBuilder
    private var terminalDetail: some View {
        if let vm = sessionsVM,
           let id = selectedSession,
           let session = vm.session(withID: id) {
            SessionTerminalView(session: session, service: vm.service)
                .id(session.id)
        } else {
            ContentUnavailableView(
                "Selecciona una sesión",
                systemImage: "terminal",
                description: Text("Elige una sesión de la lista para abrir su terminal en vivo.")
            )
        }
    }

    // MARK: - Acciones de servidores

    private func save(_ server: Server, passphrase: String?) {
        try? KeychainStore.setPassphrase(passphrase, for: server.id)
        if store.servers.contains(where: { $0.id == server.id }) {
            store.update(server)
        } else {
            store.add(server)
            selectedServerID = server.id
        }
        // Si se editó el servidor activo, fuerza reconstruir el servicio.
        if server.id == selectedServerID {
            reloadToken += 1
        }
    }

    private func delete(_ server: Server) {
        store.remove(server)
        if selectedServerID == server.id {
            selectedServerID = store.servers.first?.id
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } })
    }

    /// Construye el servicio SSH de un servidor, recuperando su passphrase de Keychain.
    private static func makeService(for server: Server) -> SSHService {
        let passphrase = server.requiresPassphrase ? KeychainStore.passphrase(for: server.id) : nil
        return SSHService(configuration: SSHService.Configuration(server: server, passphrase: passphrase))
    }
}

// MARK: - Fila de servidor

struct ServerRow: View {
    let server: Server

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).font(.headline)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - ServerFormSheet.Mode como Identifiable para .sheet(item:)

extension ServerFormSheet.Mode: Identifiable {
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let server): return "edit-\(server.id.uuidString)"
        }
    }
}

// MARK: - Previews (datos de muestra, sin conexión real)

#if DEBUG
extension TmuxSession {
    static let samples: [TmuxSession] = [
        TmuxSession(name: "main",    windowCount: 3, isAttached: true,  createdAt: .now.addingTimeInterval(-3600)),
        TmuxSession(name: "deploy",  windowCount: 1, isAttached: false, createdAt: .now.addingTimeInterval(-86_400)),
        TmuxSession(name: "logs",    windowCount: 5, isAttached: false, createdAt: .now.addingTimeInterval(-120))
    ]
}

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
