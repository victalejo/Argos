//
//  ContentView.swift
//  Argos
//
//  Raíz de la app: NavigationSplitView de 3 columnas —
//  servidores → sesiones tmux de TODOS los servidores → terminal en vivo.
//

import SwiftUI

// MARK: - Identificador de sesión en el contexto multi-servidor

struct SessionHandle: Hashable, Sendable {
    let serverID: Server.ID
    let sessionID: TmuxSession.ID
}

// MARK: - Root view

struct ContentView: View {
    @State private var store = ServerStore()
    @State private var selectedServerID: Server.ID?
    @State private var selectedSession: SessionHandle?
    /// Un ViewModel por servidor (se crea al añadir, se destruye al eliminar).
    @State private var vms: [Server.ID: SessionsViewModel] = [:]

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
            syncVMs()
            if selectedServerID == nil { selectedServerID = store.servers.first?.id }
        }
        .onChange(of: store.servers) { _, _ in syncVMs() }
        .sheet(item: $serverFormMode) { mode in
            ServerFormSheet(mode: mode) { server, secret in
                save(server, secret: secret)
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
            ForEach(store.servers) { server in
                ServerRow(server: server, connectionState: vms[server.id]?.state)
                    .tag(server.id)
                    .contextMenu {
                        Button("Editar…") { serverFormMode = .edit(server) }
                        Divider()
                        Button("Olvidar host key") {
                            TOFUHostKeyValidator.forget(host: server.host, port: server.port)
                        }
                        Divider()
                        Button("Eliminar…", role: .destructive) { serverToDelete = server }
                    }
            }

            // Botón "Añadir servidor" dentro de la lista para no confundir con el
            // "+" de la columna de sesiones que va en el toolbar principal.
            Button {
                serverFormMode = .add
            } label: {
                Label("Añadir servidor", systemImage: "plus.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
        .navigationTitle("Argos")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    // MARK: - Columna 2: sesiones (todos los servidores)

    @ViewBuilder
    private var sessionsContent: some View {
        if store.servers.isEmpty {
            ContentUnavailableView {
                Label("Sin servidores", systemImage: "server.rack")
            } description: {
                Text("Añade un servidor para ver sus sesiones tmux.")
            } actions: {
                Button("Añadir servidor") { serverFormMode = .add }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            SessionsColumn(
                servers: store.servers,
                vms: vms,
                activeServerID: selectedServerID,
                selection: $selectedSession
            )
        }
    }

    // MARK: - Columna 3: terminal

    @ViewBuilder
    private var terminalDetail: some View {
        if let handle = selectedSession,
           let vm = vms[handle.serverID],
           let session = vm.session(withID: handle.sessionID) {
            SessionTerminalView(session: session, service: vm.service)
                .id(handle)
        } else {
            ContentUnavailableView(
                "Selecciona una sesión",
                systemImage: "terminal",
                description: Text("Elige una sesión de la lista para abrir su terminal en vivo.")
            )
        }
    }

    // MARK: - Gestión de VMs

    /// Mantiene `vms` en sync con `store.servers`: crea VMs para nuevos servidores,
    /// elimina las de servidores borrados.
    private func syncVMs() {
        let serverIDs = Set(store.servers.map { $0.id })
        for id in vms.keys where !serverIDs.contains(id) {
            vms.removeValue(forKey: id)
        }
        for server in store.servers where vms[server.id] == nil {
            let vm = SessionsViewModel(service: Self.makeService(for: server))
            vms[server.id] = vm
            Task { await vm.load() }
        }
    }

    // MARK: - Acciones de servidores

    /// `secret` es la passphrase (auth por clave) o la contraseña (auth por contraseña),
    /// según `server.authMethod`. Se guarda en el namespace de Keychain correspondiente.
    private func save(_ server: Server, secret: String?) {
        switch server.authMethod {
        case .key:
            try? KeychainStore.setPassphrase(secret, for: server.id)
            KeychainStore.deletePassword(for: server.id)
        case .password:
            try? KeychainStore.setPassword(secret, for: server.id)
            KeychainStore.deletePassphrase(for: server.id)
        }
        if store.servers.contains(where: { $0.id == server.id }) {
            store.update(server)
        } else {
            store.add(server)
            selectedServerID = server.id
        }
        // Reconstruye el VM del servidor editado (credenciales pueden haber cambiado).
        let vm = SessionsViewModel(service: Self.makeService(for: server))
        vms[server.id] = vm
        Task { await vm.load() }
    }

    private func delete(_ server: Server) {
        store.remove(server)
        vms.removeValue(forKey: server.id)
        KeychainStore.deletePassphrase(for: server.id)
        KeychainStore.deletePassword(for: server.id)
        if selectedServerID == server.id {
            selectedServerID = store.servers.first?.id
        }
        if let handle = selectedSession, handle.serverID == server.id {
            selectedSession = nil
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { serverToDelete != nil }, set: { if !$0 { serverToDelete = nil } })
    }

    private static func makeService(for server: Server) -> SSHService {
        switch server.authMethod {
        case .key:
            let passphrase = server.requiresPassphrase ? KeychainStore.passphrase(for: server.id) : nil
            return SSHService(configuration: SSHService.Configuration(server: server, passphrase: passphrase))
        case .password:
            let password = KeychainStore.password(for: server.id)
            return SSHService(configuration: SSHService.Configuration(server: server, password: password))
        }
    }
}

// MARK: - Fila de servidor

struct ServerRow: View {
    let server: Server
    var connectionState: SessionsLoadState? = nil

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).font(.headline)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connectionState {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .loaded:
            Image(systemName: "server.rack")
                .foregroundStyle(.green)
        case .some:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case nil:
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
        }
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

// MARK: - Previews

#if DEBUG
extension TmuxSession {
    static let samples: [TmuxSession] = [
        TmuxSession(name: "main",    windowCount: 3, isAttached: true,  createdAt: .now.addingTimeInterval(-3600)),
        TmuxSession(name: "deploy",  windowCount: 1, isAttached: false, createdAt: .now.addingTimeInterval(-86_400)),
        TmuxSession(name: "logs",    windowCount: 5, isAttached: false, createdAt: .now.addingTimeInterval(-120))
    ]
}

#Preview("Fila de servidor") {
    List {
        ServerRow(server: Server(name: "dev", host: "100.86.237.26", port: 2222, username: "victalejo", privateKeyPath: "~/.ssh/id_ed25519"))
        ServerRow(server: Server(name: "prod", host: "prod.example.com", port: 22, username: "deploy", privateKeyPath: "~/.ssh/id_ed25519"), connectionState: .failed("Timeout"))
    }
    .frame(width: 240, height: 160)
}
#endif
