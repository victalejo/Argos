//
//  AgentPanelView.swift
//  Argos
//
//  Pestaña "Agente" de un proyecto: Claude Code headless en la CARPETA DEL PROYECTO
//  (sin elegir carpetas), con varias conversaciones en pestañas. Arranca solo en cuanto
//  el servidor tiene Claude instalado y con sesión iniciada; si no, guía para
//  instalarlo o conectarlo (`ClaudeSetupSheet`). Antes de arrancar un agente comprueba
//  que el servidor tenga memoria libre (cada `claude` ocupa ~0,5 GB).
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Por debajo de esto no se arranca un agente sin confirmación (KB).
    static let minimumFreeMemoryKB = 900_000

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
            authChip
            Menu {
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
            onClose: { store.closeTab($0, for: handle) },
            onNew: { Task { await newConversation(force: false) } }
        )
        Divider()
        if let tab = store.selectedTab(for: handle) {
            AgentConversationView(session: tab.session, title: title)
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

    // MARK: - Flujo

    /// Resuelve carpeta, instalación y sesión; si todo está listo y no hay
    /// conversaciones, arranca la primera automáticamente.
    private func prepare() async {
        readiness = .checking
        do {
            if let projectPath {
                folder = projectPath
            } else {
                folder = try await service.sessionFirstPanePaths()[handle.sessionID]
            }
            guard folder != nil else { readiness = .noFolder; return }

            claudePath = try await service.locateClaude()
            guard claudePath != nil else { readiness = .notInstalled; return }

            authStatus = try await service.claudeAuthStatus()
            guard authStatus?.loggedIn == true || KeychainStore.hasClaudeOAuthToken() else {
                readiness = .loggedOut
                return
            }
            readiness = .ready
            if store.tabs(for: handle).isEmpty {
                await newConversation(force: false)
            }
        } catch {
            readiness = .failed(error.userMessage)
        }
    }

    /// Abre una conversación nueva (nueva pestaña) en la carpeta del proyecto.
    private func newConversation(force: Bool) async {
        guard let folder, let claudePath, !isStartingTab else { return }
        isStartingTab = true
        defer { isStartingTab = false }

        if !force, let free = try? await service.availableMemoryKB(), free < Self.minimumFreeMemoryKB {
            readiness = .lowMemory(
                "Quedan \(ResourceFormat.kilobytes(free)) libres y cada conversación de Claude ocupa "
                + "unos 0,5 GB. Detén proyectos en segundo plano (menú ⋯ del servidor) para liberar memoria."
            )
            return
        }
        readiness = .ready
        let command = ClaudeAgentCommand.build(
            claudePath: claudePath,
            workingDirectory: folder,
            oauthToken: KeychainStore.claudeOAuthToken(),
            sessionID: UUID().uuidString.lowercased()
        )
        store.newTab(for: handle, service: service, command: command, workingDirectory: folder)
    }

    private func startLogin() {
        guard let claudePath else { return }
        setupPurpose = .login(command: "\(ShellQuoting.singleQuoted(claudePath)) auth login --claudeai")
    }
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
                .keyboardShortcut("t", modifiers: .command)
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
                    Text(tab.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Conversación: \(tab.title)")
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
