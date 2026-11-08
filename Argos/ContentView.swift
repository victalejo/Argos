//
//  ContentView.swift
//  Argos
//
//  Raíz de la app: NavigationSplitView de 3 columnas —
//  servidores → proyectos y sesiones de TODOS los servidores → terminal en vivo.
//

import SwiftUI

// MARK: - Root view

struct ContentView: View {
    @State private var store = ServerStore()
    @State private var selectedServerID: Server.ID?
    @State private var selectedSession: SessionHandle?
    /// Un ViewModel por servidor (se crea al añadir, se destruye al eliminar).
    @State private var vms: [Server.ID: SessionsViewModel] = [:]

    @State private var serverFormMode: ServerFormSheet.Mode?
    @State private var serverToDelete: Server?
    /// Servidor en el que se va a activar el indicador de Claude Code (confirmación).
    @State private var claudeHooksServer: Server?
    /// Servidor que se está enviando al iPhone por QR.
    @State private var transferServer: Server?
    /// Servidor cuyos dispositivos autorizados (claves de iPhone/iPad) se están viendo.
    @State private var devicesServer: Server?
    /// Resultado de activar el indicador (alerta).
    @State private var claudeHooksResult: String?

    /// Pool persistente de terminales en vivo (conexiones que sobreviven al cambio de
    /// selección) y fuente de los estados de cada sesión.
    @State private var terminalStore = TerminalSessionStore()

    /// Pool de agentes de Claude Code (opción "Agente" de la 3ª columna), vivos aunque
    /// cambies de sesión o de modo.
    @State private var agentStore = AgentSessionStore()

    #if APPSTORE
    /// Sincronización de servidores y huellas con iPhone/iPad por iCloud (solo el canal
    /// App Store: la de GitHub no tiene el entitlement de iCloud).
    @State private var cloudSync: CloudServerSync?
    #endif

    /// Modo elegido por sesión en la 3ª columna (terminal por defecto).
    @State private var detailModes: [SessionHandle: DetailMode] = [:]

    @State private var quickSwitcher = QuickSwitcher.shared
    @State private var showSSHConfig = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Último servidor seleccionado (persistido entre arranques de la escena). Se guarda
    /// como `uuidString` porque `@SceneStorage` no admite `UUID` directamente.
    @SceneStorage("selectedServerID") private var persistedServerID = ""

    private var workspace: some View {
        NavigationSplitView {
            serverSidebar
        } content: {
            sessionsContent
        } detail: {
            terminalDetail
        }
        .tint(ArgosTheme.controlAccent)
        .frame(minWidth: 1040, minHeight: 640)
        .onAppear {
            #if APPSTORE
            startCloudSync()
            #endif
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
        .sheet(item: $transferServer) { server in
            if let service = vms[server.id]?.service {
                ServerTransferSheet(server: server, service: service) { transferServer = nil }
            }
        }
        .sheet(item: $devicesServer) { server in
            if let service = vms[server.id]?.service {
                AuthorizedDevicesSheet(server: server, service: service) { devicesServer = nil }
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
    }

    var body: some View {
        workspace
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
        .confirmationDialog(
            claudeHooksServer.map { "¿Activar el indicador de Claude Code en '\($0.name)'?" } ?? "",
            isPresented: Binding(
                get: { claudeHooksServer != nil },
                set: { if !$0 { claudeHooksServer = nil } }
            ),
            titleVisibility: .visible,
            presenting: claudeHooksServer
        ) { server in
            Button("Activar") { installClaudeHooks(on: server) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Se añadirán hooks a ~/.claude/settings.json del servidor (con copia en "
                 + "settings.json.argos-backup; tus hooks actuales se conservan). Avisan a Argos "
                 + "cuando Claude trabaja, termina o espera tu respuesta. Las sesiones de Claude "
                 + "ya abiertas deben reiniciarse para usarlos.")
        }
        .alert(
            "Indicador de Claude Code",
            isPresented: Binding(
                get: { claudeHooksResult != nil },
                set: { if !$0 { claudeHooksResult = nil } }
            ),
            presenting: claudeHooksResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Columna 1: servidores

    private var serverSidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().padding(.horizontal, 16)
            serverList
            sidebarActions
        }
        .background(ArgosTheme.canvas.opacity(0.6))
        .navigationTitle("Argos")
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                WorkspaceIcon(symbol: "square.stack.3d.up.fill", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Argos").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("Tu espacio de trabajo remoto")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("SERVIDORES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.servers.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.primary.opacity(0.05), in: Capsule())
            }
        }
        .padding(16)
    }

    private var serverList: some View {
        List(selection: $selectedServerID) {
            ForEach(store.servers) { server in
                HStack(spacing: 2) {
                    ServerRow(server: server, connectionState: vms[server.id]?.state)
                    Menu {
                        serverActions(for: server)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Opciones de \(server.name)")
                    .accessibilityLabel("Opciones del servidor \(server.name)")
                }
                .tag(server.id)
                .contextMenu { serverActions(for: server) }
            }

        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.title2).foregroundStyle(.tertiary)
                    Text("Tus servidores aparecerán aquí")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func serverActions(for server: Server) -> some View {
        Button("Editar servidor…", systemImage: "pencil") { serverFormMode = .edit(server) }
        Divider()
        Button("Enviar al iPhone…", systemImage: "qrcode") { transferServer = server }
            .disabled(vms[server.id] == nil)
            .help("Muestra un QR para añadir este servidor en Argos para iPhone/iPad")
        Button("Dispositivos autorizados…", systemImage: "lock.iphone") { devicesServer = server }
            .disabled(vms[server.id] == nil)
            .help("Ver y revocar los iPhone/iPad con acceso a este servidor")
        Button("Activar indicador de Claude Code…") { claudeHooksServer = server }
            .disabled(vms[server.id] == nil)
        Divider()
        Button("Olvidar host key") {
            TOFUHostKeyValidator.forget(host: server.host, port: server.port)
        }
        Divider()
        Button("Eliminar servidor…", role: .destructive) { serverToDelete = server }
    }

    private var sidebarActions: some View {
        VStack(spacing: 8) {
            Button { serverFormMode = .add } label: {
                Label("Añadir servidor", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button { showSSHConfig = true } label: {
                Label("Importar configuración SSH", systemImage: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help("Importar servidores de ~/.ssh/config")
            Divider().padding(.vertical, 3)
            Button { quickSwitcher.present() } label: {
                HStack {
                    Label("Cambiar de sesión", systemImage: "magnifyingglass")
                        .font(.caption)
                    Spacer(minLength: 2)
                    KeyboardHint(keys: "⌘ K")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Buscar una sesión en todos tus servidores (⌘K)")
        }
        .padding(14)
        .background(.bar)
    }

    // MARK: - Columna 2: sesiones (todos los servidores)

    @ViewBuilder
    private var sessionsContent: some View {
        if store.servers.isEmpty {
            VStack(spacing: 20) {
                WorkspaceIcon(symbol: "server.rack", size: 64)
                VStack(spacing: 7) {
                    Text("Conecta tu primer servidor")
                        .font(.title3.weight(.semibold))
                    Text("Reúne tus proyectos y sesiones SSH en un solo lugar.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Añadir servidor") { serverFormMode = .add }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspaceBackdrop())
        } else {
            SessionsColumn(
                servers: store.servers,
                vms: vms,
                terminalStore: terminalStore,
                agentStore: agentStore,
                activeServerID: selectedServerID,
                selection: $selectedSession
            )
        }
    }

    // MARK: - Columna 3: terminal (por defecto) o agente Claude Code

    @ViewBuilder
    private var terminalDetail: some View {
        if let handle = selectedSession,
           let vm = vms[handle.serverID],
           vm.session(withID: handle.sessionID) != nil || vm.project(forSession: handle.sessionID) != nil {
            VStack(spacing: 0) {
                detailModePicker(for: handle)
                Divider()
                detailContent(
                    handle: handle,
                    session: vm.session(withID: handle.sessionID),
                    project: vm.project(forSession: handle.sessionID),
                    vm: vm
                )
            }
        } else {
            welcomeWorkspace
        }
    }

    /// Conmutador Terminal | Archivos | Agente. El terminal tmux es el modo por defecto.
    private func detailModePicker(for handle: SessionHandle) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                detailIdentity(for: handle)
                Spacer(minLength: 12)
                modeControl(for: handle)
            }
            VStack(alignment: .leading, spacing: 12) {
                detailIdentity(for: handle)
                modeControl(for: handle)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func detailIdentity(for handle: SessionHandle) -> some View {
        let project = vms[handle.serverID]?.project(forSession: handle.sessionID)
        let serverName = store.server(withID: handle.serverID)?.name ?? "Servidor"
        return HStack(spacing: 10) {
            WorkspaceIcon(symbol: project == nil ? "terminal" : "folder.fill", size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(project?.name ?? handle.sessionID)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(project?.name ?? handle.sessionID)
                Label(serverName, systemImage: "server.rack")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func modeControl(for handle: SessionHandle) -> some View {
        Picker("Modo de trabajo", selection: detailModeBinding(for: handle)) {
            Label("Terminal", systemImage: "terminal").tag(DetailMode.terminal)
            Label("Archivos", systemImage: "folder").tag(DetailMode.files)
            Label("Agente", systemImage: "sparkles").tag(DetailMode.agent)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.large)
        .help("Elige cómo trabajar en este proyecto")
    }

    private var welcomeWorkspace: some View {
        ScrollView {
            VStack(spacing: 28) {
                WorkspaceIcon(symbol: "square.stack.3d.up.fill", size: 80)
                VStack(spacing: 10) {
                    Text("Todo listo para trabajar")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Selecciona un proyecto y continúa donde lo dejaste.")
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 0) {
                    workspaceFeature("Tu terminal, siempre a mano", detail: "Abre sesiones y cambia entre ventanas.", icon: "terminal")
                    Divider().padding(.leading, 62)
                    workspaceFeature("Explora tus archivos", detail: "Consulta código, imágenes y documentos.", icon: "folder")
                    Divider().padding(.leading, 62)
                    workspaceFeature("Dale una tarea a tu agente", detail: "Trabaja con Claude Code en cada proyecto.", icon: "sparkles")
                }
                .background(ArgosTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(ArgosTheme.border) }
                Button { quickSwitcher.present() } label: {
                    HStack(spacing: 10) {
                        Label("Buscar una sesión", systemImage: "magnifyingglass")
                        KeyboardHint(keys: "⌘ K")
                    }
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(quickSwitchItems.isEmpty)
            }
            .frame(maxWidth: 450)
            .padding(.horizontal, 36).padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceBackdrop())
    }

    private func workspaceFeature(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func detailModeBinding(for handle: SessionHandle) -> Binding<DetailMode> {
        Binding(
            get: { detailModes[handle] ?? .terminal },
            set: { mode in
                withAnimation(ArgosTheme.motion(reduceMotion: reduceMotion)) {
                    detailModes[handle] = mode
                }
            }
        )
    }

    /// Contenido de la 3ª columna. `session` es `nil` si el proyecto está detenido;
    /// `project` es `nil` si es una sesión suelta.
    @ViewBuilder
    private func detailContent(
        handle: SessionHandle,
        session: TmuxSession?,
        project: Project?,
        vm: SessionsViewModel
    ) -> some View {
        switch detailModes[handle] ?? .terminal {
        case .terminal:
            if let session {
                SessionTerminalView(
                    handle: handle,
                    session: session,
                    service: vm.service,
                    store: terminalStore,
                    claudeByWindow: vm.claudeActivity.windows(forSession: session.name),
                    projectPath: project?.path,
                    serverName: store.server(withID: handle.serverID)?.name ?? ""
                )
                .id(handle)
            } else if let project {
                // Proyecto detenido: al abrirlo aparece su sesión y esta rama cede al terminal.
                ProjectStoppedView(project: project, vm: vm)
                    .id(project.id)
            }
        case .files:
            if let project {
                FilesPanelView(root: project.path, service: vm.service)
                    .id(handle)
            } else {
                LooseSessionFilesView(sessionName: handle.sessionID, service: vm.service)
                    .id(handle)
            }
        case .agent:
            AgentPanelView(
                handle: handle,
                service: vm.service,
                store: agentStore,
                title: project?.name ?? handle.sessionID,
                serverName: store.servers.first { $0.id == handle.serverID }?.name ?? "el servidor",
                projectPath: project?.path
            )
            .id(handle)
        }
    }

    // MARK: - Indicador de Claude Code

    private func installClaudeHooks(on server: Server) {
        guard let vm = vms[server.id] else { return }
        Task {
            do {
                if try await vm.service.claudeHooksInstalled() {
                    claudeHooksResult = "El indicador ya estaba activo en \(server.name)."
                    return
                }
                try await vm.service.installClaudeHooks()
                claudeHooksResult = "Indicador activado en \(server.name). Reinicia las sesiones de "
                    + "Claude Code que ya estuvieran abiertas para que empiecen a reportar su estado."
            } catch {
                Log.ssh.error("Instalar hooks de Claude: \(error.userMessage, privacy: .public)")
                claudeHooksResult = "No se pudo activar el indicador: \(error.userMessage)"
            }
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
        // Cierra sus terminales y agentes: deben re-attacharse con el servicio nuevo.
        terminalStore.closeAll(forServer: server.id)
        agentStore.closeAll(forServer: server.id)
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

    #if APPSTORE
    private func startCloudSync() {
        guard cloudSync == nil else { return }
        let sync = CloudServerSync(store: store)
        // Borrado en otro dispositivo: limpiar lo de este Mac (conexiones y secretos).
        sync.onRemoteRemoval = { server in forgetLocally(server) }
        sync.start()
        cloudSync = sync
    }
    #endif

    private func delete(_ server: Server) {
        store.remove(server)
        forgetLocally(server)
    }

    /// Lo propio de este Mac de un servidor que ya no está (conexiones, secretos, selección).
    private func forgetLocally(_ server: Server) {
        vms.removeValue(forKey: server.id)
        terminalStore.closeAll(forServer: server.id)
        agentStore.closeAll(forServer: server.id)
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
        server.makeService()
    }
}

// MARK: - Fila de servidor

struct ServerRow: View {
    let server: Server
    var connectionState: SessionsLoadState? = nil

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(accessibilityStateText.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .help("\(server.username)@\(server.host):\(server.port)")
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
        case .idle, nil: return "sin conectar"
        case .some: return "conectando"
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
        case .idle, nil:
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
        case .some:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
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
