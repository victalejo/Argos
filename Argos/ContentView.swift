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

    /// Pool persistente de terminales en vivo (conexiones que sobreviven al cambio de
    /// selección) y fuente de los estados de cada sesión.
    @State private var terminalStore = TerminalSessionStore()

    @State private var quickSwitcher = QuickSwitcher.shared
    @State private var showSSHConfig = false

    /// Último servidor seleccionado (persistido entre arranques de la escena). Se guarda
    /// como `uuidString` porque `@SceneStorage` no admite `UUID` directamente.
    @SceneStorage("selectedServerID") private var persistedServerID = ""

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
            if selectedServerID == nil {
                selectedServerID = restoredServerID() ?? store.servers.first?.id
            }
            loadSelectedIfNeeded()
        }
        .onChange(of: store.servers) { _, _ in syncVMs() }
        .onChange(of: selectedServerID) { _, newValue in
            persistedServerID = newValue?.uuidString ?? ""
            loadSelectedIfNeeded()
        }
        .sheet(item: $serverFormMode) { mode in
            ServerFormSheet(mode: mode) { server, secret in
                save(server, secret: secret)
            }
        }
        .sheet(isPresented: $showSSHConfig) {
            SSHConfigSheet(
                existingServers: store.servers,
                onImport: { importHost($0) },
                onClose: { showSSHConfig = false }
            )
        }
        // Switcher en un subview propio para no competir con el sheet del formulario.
        .background(
            Color.clear.sheet(isPresented: $quickSwitcher.isPresented) {
                QuickSwitcherView(
                    items: quickSwitchItems,
                    onSelect: { handle in
                        selectedServerID = handle.serverID
                        selectedSession = handle
                        quickSwitcher.isPresented = false
                    },
                    onCancel: { quickSwitcher.isPresented = false }
                )
            }
        )
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

            Button {
                showSSHConfig = true
            } label: {
                Label("Importar de ~/.ssh/config…", systemImage: "list.bullet.rectangle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
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
                terminalStore: terminalStore,
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
            SessionTerminalView(handle: handle, session: session, service: vm.service, store: terminalStore)
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

    /// Servidor persistido de un arranque anterior, si todavía existe en el store.
    private func restoredServerID() -> Server.ID? {
        guard let uuid = UUID(uuidString: persistedServerID) else { return nil }
        return store.servers.first { $0.id == uuid }?.id
    }

    /// Mantiene `vms` en sync con `store.servers`: crea VMs para nuevos servidores,
    /// elimina las de servidores borrados.
    private func syncVMs() {
        let serverIDs = Set(store.servers.map { $0.id })
        for id in vms.keys where !serverIDs.contains(id) {
            vms.removeValue(forKey: id)
        }
        // Arranque perezoso: solo se CREAN los VMs. La carga (bootstrap + listar) se
        // dispara on-demand para el servidor seleccionado (ver `loadSelectedIfNeeded`),
        // en vez de conectar a TODOS los servidores a la vez al abrir la app.
        for server in store.servers where vms[server.id] == nil {
            vms[server.id] = SessionsViewModel(service: Self.makeService(for: server))
        }
    }

    /// Carga el servidor seleccionado solo si su VM sigue sin cargar (`.idle`). No toca
    /// los demás servidores: conectarse a ellos se difiere hasta que los selecciones (o
    /// pulses "Conectar" en su sección).
    private func loadSelectedIfNeeded() {
        guard let id = selectedServerID, let vm = vms[id] else { return }
        if case .idle = vm.state {
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
        // Cierra sus terminales: deben re-attacharse con el servicio nuevo.
        terminalStore.closeAll(forServer: server.id)
        let vm = SessionsViewModel(service: Self.makeService(for: server))
        vms[server.id] = vm
        Task { await vm.load() }
    }

    /// Crea un servidor de Argos a partir de un host de `~/.ssh/config`. Auth por clave
    /// (la passphrase, si la hubiera, se pide al editar). No cierra el visor: puedes
    /// importar varios.
    private func importHost(_ host: SSHConfigHost) {
        let server = Server(
            name: host.alias,
            host: host.effectiveHost,
            port: host.port ?? 22,
            username: host.user ?? "",
            authMethod: .key,
            privateKeyPath: host.identityFile ?? "~/.ssh/id_ed25519"
        )
        save(server, secret: nil)
    }

    private func delete(_ server: Server) {
        store.remove(server)
        vms.removeValue(forKey: server.id)
        terminalStore.closeAll(forServer: server.id)
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

    /// Todas las sesiones (de todos los servidores) para el cambiador rápido (⌘K).
    private var quickSwitchItems: [QuickSwitchItem] {
        store.servers.flatMap { server in
            (vms[server.id]?.sessions ?? []).map { session in
                QuickSwitchItem(
                    handle: SessionHandle(serverID: server.id, sessionID: session.id),
                    serverName: server.name,
                    sessionName: session.name
                )
            }
        }
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
                .accessibilityHidden(true)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(server.name), \(server.username) en \(server.host) puerto \(server.port), \(accessibilityStateText)")
    }

    /// Estado de conexión en texto, para VoiceOver (refuerza el color del icono).
    private var accessibilityStateText: String {
        switch connectionState {
        case .failed: return "error de conexión"
        case .hostKeyChanged: return "identidad del servidor cambiada"
        case .tmuxMissing: return "tmux no instalado"
        case .loaded: return "conectado"
        case .some: return "conectando"
        case nil: return "sin cargar"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connectionState {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .hostKeyChanged:
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
        case .tmuxMissing:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
