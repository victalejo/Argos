//
//  AgentPanelView.swift
//  Argos
//
//  Pestaña "Agente" de un proyecto: Claude Code headless en la CARPETA DEL PROYECTO
//  (sin elegir carpetas), con varias conversaciones en pestañas. Arranca solo en cuanto
//  el servidor tiene Claude instalado y con sesión iniciada; si no, guía para
//  instalarlo o conectarlo (`ClaudeSetupSheet`). Antes de arrancar un agente comprueba
//  que el servidor tenga memoria libre (cada `claude` ocupa ~0,5 GB) y, al llegar al
//  tope de conversaciones, pregunta cuál cerrar. Las conversaciones cerradas se pueden
//  reanudar (`--resume`).
//

import SwiftUI

struct AgentPanelView: View {
    let handle: SessionHandle
    let service: any SSHServicing
    let store: AgentSessionStore
    /// Nombre visible (proyecto o sesión) y servidor, para los textos.
    let title: String
    let serverName: String
    /// Carpeta del proyecto; `nil` en una sesión suelta (se usa la de su primer panel).
    let projectPath: String?

    private enum Readiness: Equatable {
        case checking
        case noFolder
        case notInstalled
        case loggedOut
        case ready
        case lowMemory(String)
        case failed(String)
    }

    @State private var readiness: Readiness = .checking
    @State private var folder: String?
    @State private var claudePath: String?
    @State private var authStatus: ClaudeAuthStatus?
    @State private var setupPurpose: ClaudeSetupSheet.Purpose?
    @State private var showTokenSheet = false
    @State private var isStartingTab = false
    /// Pestaña que se va a cerrar estando ocupada (se pide confirmación).
    @State private var closeCandidate: AgentTabEntry?
    /// Tope de conversaciones alcanzado: hay que elegir cuál cerrar.
    @State private var isChoosingEviction = false
    /// Lo que se quería abrir cuando se llegó al tope (se hace al cerrar otra).
    @State private var pendingOpen: PendingOpen?

    private enum PendingOpen {
        case newConversation
        case resume(UUID)
        case reopen(ClosedAgentConversation)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Por debajo de esto no se arranca un agente sin confirmación (KB).
    static let minimumFreeMemoryKB = AgentLaunchGuard.minimumFreeMemoryKB

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: handle) { await prepare() }
        .sheet(item: Binding(
            get: { setupPurpose.map(SetupRequest.init) },
            set: { setupPurpose = $0?.purpose }
        )) { request in
            ClaudeSetupSheet(service: service, serverName: serverName, purpose: request.purpose) { _ in
                setupPurpose = nil
                Task { await prepare() }
            }
        }
        .sheet(isPresented: $showTokenSheet) {
            AgentTokenSheet {
                showTokenSheet = false
                Task { await prepare() }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: readiness)
        .focusedSceneValue(\.tabActions, tabActions)
        .confirmationDialog(
            "¿Cerrar esta conversación?",
            isPresented: Binding(get: { closeCandidate != nil }, set: { if !$0 { closeCandidate = nil } }),
            titleVisibility: .visible,
            presenting: closeCandidate
        ) { entry in
            Button("Cerrar y detener Claude", role: .destructive) {
                store.closeTab(entry.tab.id, for: entry.handle)
                runPendingOpen()
            }
            Button("Cancelar", role: .cancel) { pendingOpen = nil }
        } message: { entry in
            Text(entry.tab.session.state.pendingPermission != nil
                 ? "Claude espera tu permiso en «\(entry.tab.title)». Si la cierras, se detiene sin terminar."
                 : "Claude está trabajando en «\(entry.tab.title)». Si la cierras, se detiene a medias.")
        }
        .confirmationDialog(
            "Ya hay \(AgentSessionStore.maxLiveSessions) conversaciones abiertas",
            isPresented: $isChoosingEviction,
            titleVisibility: .visible
        ) {
            ForEach(store.allTabs.filter { $0.tab.session.isRunning }) { entry in
                Button("Cerrar «\(entry.tab.title)» (\(entry.handle.sessionID))", role: .destructive) {
                    requestClose(entry)
                }
            }
            Button("Cancelar", role: .cancel) { pendingOpen = nil }
        } message: {
            Text("Cada una es un Claude en el servidor (~0,5 GB). Elige cuál cerrar para abrir otra; podrás reanudarla después.")
        }
    }

    /// Cierra la pestaña, pidiendo confirmación si está trabajando o espera un permiso;
    /// después hace lo que estuviera pendiente de abrir (si se llegó al tope).
    private func requestClose(_ entry: AgentTabEntry) {
        if entry.tab.session.isBusy {
            closeCandidate = entry
        } else {
            store.closeTab(entry.tab.id, for: entry.handle)
            runPendingOpen()
        }
    }

    private func requestClose(_ tab: AgentTab) {
        requestClose(AgentTabEntry(handle: handle, tab: tab))
    }

    /// Tope alcanzado: se pregunta qué cerrar y luego se abre `open`.
    private func askEviction(then open: PendingOpen) {
        pendingOpen = open
        isChoosingEviction = true
    }

    private func runPendingOpen() {
        guard let open = pendingOpen else { return }
        pendingOpen = nil
        switch open {
        case .newConversation:
            Task { await newConversation(force: false) }
        case .resume(let tabID):
            if let tab = store.tabs(for: handle).first(where: { $0.id == tabID }) { resume(tab) }
        case .reopen(let conversation):
            reopen(conversation)
        }
    }

    /// Atajos de la barra de menús en modo Agente: ⌘T nueva conversación, ⌘W cerrar la
    /// actual, ⌘1…⌘9 y ⌘⇧[ ⌘⇧] para moverse entre conversaciones.
    private var tabActions: TabActions? {
        guard readiness == .ready else { return nil }
        let tabs = store.tabs(for: handle)
        return TabActions(
            identity: AgentTabIdentity(
                handle: handle,
                tabIDs: tabs.map(\.id),
                selectedID: store.selectedTab(for: handle)?.id
            ),
            newTitle: "Nueva conversación",
            closeTitle: "Cerrar conversación",
            newTab: { Task { await newConversation(force: false) } },
            closeTab: {
                if let tab = store.selectedTab(for: handle) {
                    requestClose(tab)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            },
            selectTab: { number in
                let tabs = store.tabs(for: handle)
                if let position = WindowTabs.position(forShortcut: number, count: tabs.count) {
                    store.select(tabs[position].id, for: handle)
                }
            },
            selectAdjacent: { offset in
                let tabs = store.tabs(for: handle)
                let current = tabs.firstIndex { $0.id == store.selectedTab(for: handle)?.id } ?? 0
                if let position = WindowTabs.adjacentPosition(current: current, offset: offset, count: tabs.count) {
                    store.select(tabs[position].id, for: handle)
                }
            },
            newAgent: nil,
            installedAgents: nil
        )
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Claude Code").font(.headline)
                    Text("BETA")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.tint)
                }
                if let folder {
                    Label(ProjectRow.shortPath(folder), systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("El agente trabaja en \(folder)")
                }
            }
            Spacer()
            if let folder {
                AgentPermissionPicker(serverID: handle.serverID, workingDirectory: folder)
                    .id(AgentPermissionPreferences.projectKey(serverID: handle.serverID, workingDirectory: folder))
                    .font(.caption)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            authChip
            Menu {
                closedConversationsMenu
                Button("Comprobar de nuevo") { Task { await prepare() } }
                Button("Usar un token de suscripción…") { showTokenSheet = true }
                if claudePath != nil {
                    Button("Volver a iniciar sesión en \(serverName)…") { startLogin() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Opciones de Claude Code")
            .help("Opciones y cuenta de Claude Code")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var authChip: some View {
        if let authStatus, authStatus.loggedIn {
            Label(authStatus.subscriptionType.map { "Conectado · \($0.capitalized)" } ?? "Conectado",
                  systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.teal)
                .help(authStatus.email ?? "Sesión de Claude iniciada en \(serverName)")
        } else if KeychainStore.hasClaudeOAuthToken() {
            Label("Token", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Contenido

    @ViewBuilder
    private var content: some View {
        switch readiness {
        case .checking:
            VStack(spacing: 16) {
                ProgressView().controlSize(.small)
                Text("Preparando tu agente")
                    .font(.headline)
                Text("Comprobando Claude Code en \(serverName)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noFolder:
            card(icon: "questionmark.folder", tint: .orange,
                 title: "No se sabe en qué carpeta trabajar",
                 text: "Esta sesión no es un proyecto y no se pudo leer su carpeta. Conviértela en proyecto para fijarla.")
        case .notInstalled:
            card(icon: "arrow.down.circle", tint: .blue,
                 title: "Claude Code no está instalado en \(serverName)",
                 text: "Argos puede instalarlo con el instalador oficial de Anthropic.",
                 action: ("Instalar Claude Code", { setupPurpose = .install }))
        case .loggedOut:
            card(icon: "person.badge.key", tint: .blue,
                 title: "Conecta tu cuenta de Claude",
                 text: "\(serverName) todavía no tiene sesión de Claude. Se usa tu suscripción, nunca la API de pago.",
                 action: ("Conectar Claude", { startLogin() }))
        case .lowMemory(let message):
            card(icon: "memorychip", tint: .orange,
                 title: "Poca memoria libre en \(serverName)",
                 text: message,
                 action: ("Iniciar de todos modos", { Task { await newConversation(force: true) } }))
        case .failed(let message):
            card(icon: "exclamationmark.triangle", tint: .red,
                 title: "No se pudo preparar el agente",
                 text: message,
                 action: ("Reintentar", { Task { await prepare() } }))
        case .ready:
            conversations
        }
    }

    @ViewBuilder
    private var conversations: some View {
        let tabs = store.tabs(for: handle)
        AgentTabBar(
            tabs: tabs,
            selectedID: store.selectedTab(for: handle)?.id,
            isAdding: isStartingTab,
            onSelect: { store.select($0, for: handle) },
            onClose: { id in
                if let tab = tabs.first(where: { $0.id == id }) { requestClose(tab) }
            },
            onNew: { Task { await newConversation(force: false) } }
        )
        Divider()
        if let tab = store.selectedTab(for: handle) {
            AgentConversationView(
                session: tab.session,
                title: title,
                onResume: canResume(tab) ? { resume(tab) } : nil
            )
            .id(tab.id)
        } else {
            card(icon: "bubble.left.and.text.bubble.right", tint: .accentColor,
                 title: "Sin conversaciones abiertas",
                 text: "Empieza una conversación con Claude en \(title).",
                 action: ("Nueva conversación", { Task { await newConversation(force: false) } }))
        }
    }

    private func card(
        icon: String,
        tint: Color,
        title: String,
        text: String,
        action: (String, () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 76, height: 76)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Conversaciones cerradas

    @ViewBuilder
    private var closedConversationsMenu: some View {
        let closed = store.closedConversations(for: handle)
        if !closed.isEmpty, readiness == .ready {
            Menu("Reanudar conversación cerrada") {
                ForEach(closed) { conversation in
                    Button(conversation.title) { reopen(conversation) }
                }
            }
            Divider()
        }
    }

    private func canResume(_ tab: AgentTab) -> Bool {
        !tab.session.isRunning && tab.session.hasConversation && claudePath != nil
    }

    /// Reanuda en su pestaña una conversación que terminó (p. ej. se cortó la conexión).
    private func resume(_ tab: AgentTab) {
        guard let claudePath else { return }
        guard store.capacity == .available else { askEviction(then: .resume(tab.id)); return }
        let command = ClaudeAgentCommand.build(
            claudePath: claudePath, workingDirectory: tab.session.workingDirectory,
            sessionID: tab.session.sessionID, permissionMode: tab.permissionMode, resume: true
        )
        let token = oauthTokenForLaunch
        Task { await store.resumeTab(tab.id, for: handle, service: service, command: command, oauthToken: token) }
    }

    private func reopen(_ conversation: ClosedAgentConversation) {
        guard let claudePath else { return }
        guard store.capacity == .available else { askEviction(then: .reopen(conversation)); return }
        let command = ClaudeAgentCommand.build(
            claudePath: claudePath, workingDirectory: conversation.workingDirectory,
            sessionID: conversation.sessionID, permissionMode: conversation.permissionMode, resume: true
        )
        let token = oauthTokenForLaunch
        Task { await store.reopen(conversation, for: handle, service: service, command: command, oauthToken: token) }
    }

    /// Con sesión en el servidor el token sobra: no se toca el llavero (evita su aviso).
    private var oauthTokenForLaunch: String? {
        authStatus?.loggedIn == true ? nil : KeychainStore.claudeOAuthToken()
    }

    // MARK: - Flujo

    /// Resuelve carpeta, instalación y sesión; si todo está listo y no hay
    /// conversaciones, arranca la primera automáticamente. Si ya hay pestañas (o el
    /// servidor ya se comprobó), se muestran AL INSTANTE y se verifica en segundo plano.
    private func prepare() async {
        let tabs = store.tabs(for: handle)
        let knownFolder = projectPath ?? tabs.first?.session.workingDirectory
        let cached = store.readinessCache[handle.serverID]
        let showsInstantly = knownFolder != nil && (cached != nil || !tabs.isEmpty)
        if showsInstantly {
            folder = knownFolder
            if let cached {
                claudePath = cached.claudePath
                authStatus = cached.authStatus
            }
            readiness = .ready
        } else {
            readiness = .checking
        }
        let serverID = handle.serverID
        Task { await store.cleanUpOrphans(serverID: serverID, service: service) }
        do {
            try await verify(showsInstantly: showsInstantly)
        } catch {
            if showsInstantly && !tabs.isEmpty {
                Log.agent.notice("No se pudo verificar Claude: \(error.localizedDescription, privacy: .private)")
            } else {
                readiness = .failed(error.userMessage)
            }
        }
    }

    /// Comprueba carpeta, instalación y sesión. Con pestañas abiertas, un problema no
    /// las esconde (siguen usables); sin pestañas, se muestra la tarjeta que toque.
    private func verify(showsInstantly: Bool) async throws {
        let hasTabs = !store.tabs(for: handle).isEmpty
        if folder == nil {
            if let projectPath {
                folder = projectPath
            } else {
                folder = try await service.sessionFirstPanePaths()[handle.sessionID]
            }
        }
        guard folder != nil else { readiness = .noFolder; return }

        let path = try await service.locateClaude()
        claudePath = path
        guard let path else {
            store.readinessCache[handle.serverID] = nil
            if !hasTabs { readiness = .notInstalled }
            return
        }
        let auth = try await service.claudeAuthStatus()
        authStatus = auth
        guard auth?.loggedIn == true || KeychainStore.hasClaudeOAuthToken() else {
            store.readinessCache[handle.serverID] = nil
            if !hasTabs { readiness = .loggedOut }
            return
        }
        store.readinessCache[handle.serverID] = AgentServerReadiness(claudePath: path, authStatus: auth)
        if !showsInstantly || readiness != .ready { readiness = .ready }
        if store.tabs(for: handle).isEmpty {
            await newConversation(force: false)
        }
    }

    /// Abre una conversación nueva (nueva pestaña) en la carpeta del proyecto.
    private func newConversation(force: Bool) async {
        guard let folder, let claudePath, !isStartingTab else { return }
        guard store.capacity == .available else {
            askEviction(then: .newConversation)
            return
        }
        isStartingTab = true
        defer { isStartingTab = false }

        if !force, let free = try? await service.availableMemoryKB(),
           case .warning(_, let message) = AgentLaunchGuard.assess(freeMemoryKB: free, liveAgents: 0) {
            readiness = .lowMemory(message)
            return
        }
        readiness = .ready
        let mode = AgentPermissionPreferences.effectiveMode(serverID: handle.serverID, workingDirectory: folder)
        let sessionID = UUID().uuidString.lowercased()
        let command = ClaudeAgentCommand.build(
            claudePath: claudePath,
            workingDirectory: folder,
            sessionID: sessionID,
            permissionMode: mode
        )
        store.newTab(
            for: handle,
            service: service,
            command: command,
            workingDirectory: folder,
            oauthToken: oauthTokenForLaunch,
            permissionMode: mode,
            sessionID: sessionID
        )
    }

    private func startLogin() {
        guard let claudePath else { return }
        setupPurpose = .login(command: "\(ShellQuoting.singleQuoted(claudePath)) auth login --claudeai")
    }
}

/// Identidad de las acciones de pestaña del agente (ver `TabActions.identity`).
private struct AgentTabIdentity: Hashable {
    let handle: SessionHandle
    let tabIDs: [UUID]
    let selectedID: UUID?
}

/// Envoltorio `Identifiable` para presentar `ClaudeSetupSheet` con `.sheet(item:)`.
private struct SetupRequest: Identifiable {
    let purpose: ClaudeSetupSheet.Purpose
    var id: String {
        switch purpose {
        case .install: return "install"
        case .login: return "login"
        }
    }
}

// MARK: - Barra de conversaciones

private struct AgentTabBar: View {
    let tabs: [AgentTab]
    let selectedID: UUID?
    let isAdding: Bool
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    AgentTabChip(
                        tab: tab,
                        isSelected: tab.id == selectedID,
                        onSelect: { onSelect(tab.id) },
                        onClose: { onClose(tab.id) }
                    )
                }
                Button(action: onNew) {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .disabled(isAdding)
                .accessibilityLabel("Nueva conversación")
                .help("Nueva conversación (⌘T)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }
}

private struct AgentTabChip: View {
    let tab: AgentTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    statusDot
                    Image(systemName: tab.permissionMode.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(tab.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Permisos de esta conversación: \(tab.permissionMode.title)")
            .accessibilityLabel("Conversación: \(tab.title), \(tab.permissionMode.title)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isSelected ? 1 : 0.4)
            .help("Cerrar conversación (detiene su Claude en el servidor)")
            .accessibilityLabel("Cerrar conversación \(tab.title)")
        }
        .padding(.horizontal, 10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(isHovering ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.05)))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
    }

    @ViewBuilder
    private var statusDot: some View {
        let state = tab.session.state
        if state.pendingPermission != nil {
            Image(systemName: "bell.badge.fill").font(.system(size: 9)).foregroundStyle(.orange)
        } else {
            switch state.status {
            case .working, .connecting:
                ProgressView().controlSize(.mini)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.red)
            case .finished:
                Image(systemName: "stop.circle").font(.system(size: 9)).foregroundStyle(.secondary)
            case .idle:
                Circle().fill(.green).frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Token (avanzado)

private struct AgentTokenSheet: View {
    let onClose: () -> Void
    @State private var token = ""
    @State private var hasToken = KeychainStore.hasClaudeOAuthToken()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Token de suscripción").font(.title3.weight(.semibold))
            Text("Alternativa a conectar el servidor: genera un token en tu Mac con `claude setup-token` "
                 + "y pégalo aquí. Se guarda en el Llavero y usa tu plan, nunca la API de pago.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hasToken {
                HStack {
                    Label("Hay un token guardado", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Quitar", role: .destructive) {
                        KeychainStore.deleteClaudeOAuthToken()
                        hasToken = false
                    }
                }
            } else {
                SecureField("Token (claude setup-token)", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cerrar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                if !hasToken {
                    Button("Guardar") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        do {
            try KeychainStore.setClaudeOAuthToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            onClose()
        } catch {
            self.error = error.userMessage
        }
    }
}
