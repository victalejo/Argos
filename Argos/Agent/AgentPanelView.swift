//
//  AgentPanelView.swift
//  Argos
//
//  Pestaña "Agente" de un proyecto: Claude Code headless en la CARPETA DEL PROYECTO
//  (sin elegir carpetas), con varias conversaciones en pestañas. Arranca solo en cuanto
//  el servidor tiene Claude instalado y con sesión iniciada; si no, guía para
//  instalarlo o conectarlo (`ClaudeSetupSheet`).
//
//  Cada conversación vive «solo en esta sesión» (se detiene al cerrarla o salir) o «en el
//  servidor» (agente persistente: sigue aunque se cierre Argos y se puede continuar desde
//  el iPhone). «En el servidor» lista los persistentes de la carpeta, también los creados
//  en otros dispositivos. Antes de arrancar un agente se comprueba la memoria del servidor
//  y cuántos agentes hay vivos en TODO el servidor (`AgentLaunchGuard`). Los flujos están
//  en `AgentPanelView+Flows.swift`.
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

    enum Readiness: Equatable {
        case checking
        case noFolder
        case notInstalled
        case loggedOut
        case ready
        case failed(String)
    }

    /// Lo que se quería abrir cuando se llegó al tope (se hace al cerrar otra).
    enum PendingOpen {
        case newConversation(AgentConversationPlacement)
        case resume(UUID)
        case reopen(ClosedAgentConversation)
    }

    /// Aviso de la guardia de memoria/tope pendiente de confirmar.
    struct LaunchWarning: Identifiable {
        let title: String
        let message: String
        let placement: AgentConversationPlacement
        var id: String { title }
    }

    @State var readiness: Readiness = .checking
    @State var folder: String?
    @State var claudePath: String?
    @State var authStatus: ClaudeAuthStatus?
    @State var setupPurpose: ClaudeSetupSheet.Purpose?
    @State var showTokenSheet = false
    @State var isStartingTab = false
    /// Dónde vive una conversación nueva (recordado por proyecto).
    @State var placement: AgentConversationPlacement = AgentLaunchPreferences.fallback
    /// Pestaña que se va a cerrar estando ocupada (se pide confirmación).
    @State var closeCandidate: AgentTabEntry?
    /// Tope de conversaciones alcanzado: hay que elegir cuál cerrar.
    @State var isChoosingEviction = false
    @State var pendingOpen: PendingOpen?
    @State var launchWarning: LaunchWarning?
    /// Agente persistente cuyo modo hay que confirmar antes de reanudarlo.
    @State var resumeCandidate: PersistentAgentTab?
    @State var convertingTabID: UUID?
    @State var showsProjectAgents = false
    @State var showsServerAgents = false
    @State var isRefreshingAgents = false
    @State var actionError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        withDialogs(withSheets(main))
    }

    private var main: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: handle) { await prepare() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: readiness)
        .focusedSceneValue(\.tabActions, tabActions)
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            headerTitle
            Spacer()
            if let folder {
                AgentPermissionPicker(serverID: handle.serverID, workingDirectory: folder)
                    .id(AgentPermissionPreferences.projectKey(serverID: handle.serverID, workingDirectory: folder))
                    .font(.caption)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            authChip
            optionsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var headerTitle: some View {
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
    }

    private var optionsMenu: some View {
        Menu {
            closedConversationsMenu
            Button("Agentes en este servidor…") { showsServerAgents = true }
            Button("Comprobar de nuevo") { Task { await prepare(userInitiated: true) } }
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

    @ViewBuilder
    private var authChip: some View {
        if let authStatus, authStatus.loggedIn {
            Label(authStatus.subscriptionType.map { "Conectado · \($0.capitalized)" } ?? "Conectado",
                  systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.teal)
                .help(authStatus.email ?? String(localized: "Sesión de Claude iniciada en \(serverName)"))
        } else if KeychainStore.hasClaudeOAuthToken() {
            Label("Token", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
        }
    }

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

    // MARK: - Contenido

    @ViewBuilder
    private var content: some View {
        switch readiness {
        case .checking:
            checkingView
        case .noFolder:
            AgentPanelCard(icon: "questionmark.folder", tint: .orange,
                           title: String(localized: "No se sabe en qué carpeta trabajar"),
                           text: String(localized: "Esta sesión no es un proyecto y no se pudo leer su carpeta. Conviértela en proyecto para fijarla."))
        case .notInstalled:
            AgentPanelCard(icon: "arrow.down.circle", tint: .blue,
                           title: String(localized: "Claude Code no está instalado en \(serverName)"),
                           text: String(localized: "Argos puede instalarlo con el instalador oficial de Anthropic."),
                           action: (String(localized: "Instalar Claude Code"), { setupPurpose = .install }))
        case .loggedOut:
            AgentPanelCard(icon: "person.badge.key", tint: .blue,
                           title: String(localized: "Conecta tu cuenta de Claude"),
                           text: String(localized: "\(serverName) todavía no tiene sesión de Claude. Se usa tu suscripción, nunca la API de pago."),
                           action: (String(localized: "Conectar Claude"), { startLogin() }))
        case .failed(let message):
            AgentPanelCard(icon: "exclamationmark.triangle", tint: .red,
                           title: String(localized: "No se pudo preparar el agente"),
                           text: message,
                           action: (String(localized: "Reintentar"), { Task { await prepare(userInitiated: true) } }))
        case .ready:
            conversations
        }
    }

    private var checkingView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.small)
            Text("Preparando tu agente").font(.headline)
            Text("Comprobando Claude Code en \(serverName)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var conversations: some View {
        tabBar
        Divider()
        if let slot = store.selectedSlot(for: handle) {
            AgentTabInfoBar(slot: slot, isConverting: convertingTabID == slot.id) { perform($0, on: slot) }
            Divider()
            AgentConversationView(session: slot.conversation, title: title, onResume: resumeAction(for: slot))
                .id(slot.id)
        } else {
            emptyCard
        }
    }

    private var tabBar: some View {
        let slots = store.slots(for: handle)
        return AgentTabBar(
            slots: slots,
            selectedID: store.selectedSlot(for: handle)?.id,
            isAdding: isStartingTab,
            placement: placement,
            serverAgentCount: folderAgents.count,
            onSelect: { store.select($0, for: handle) },
            onClose: { id in
                if let slot = slots.first(where: { $0.id == id }) { requestClose(slot) }
            },
            onNew: { choice in newConversationRequested(choice) },
            onShowServerAgents: { showsProjectAgents = true }
        )
        .popover(isPresented: $showsProjectAgents, arrowEdge: .bottom) { projectAgentsPopover }
    }

    private var projectAgentsPopover: some View {
        ProjectServerAgentsPopover(
            agents: folderAgents,
            openIDs: Set(store.persistentTabs.map(\.tab.session.id)),
            isRefreshing: isRefreshingAgents,
            onOpen: { agent in
                showsProjectAgents = false
                openServerAgent(agent)
            },
            onRefresh: { Task { await refreshServerAgents(userInitiated: true) } },
            onShowAll: {
                showsProjectAgents = false
                showsServerAgents = true
            }
        )
    }

    private var emptyCard: some View {
        let count = folderAgents.count
        let extra = count > 0 ? String(localized: " Hay \(count) en el servidor: ábrelos con «En el servidor».") : ""
        return AgentPanelCard(
            icon: "bubble.left.and.text.bubble.right", tint: .accentColor,
            title: String(localized: "Sin conversaciones abiertas"),
            text: String(localized: "Empieza una conversación con Claude en \(title) (\(placement.title.lowercased())).\(extra)"),
            action: (String(localized: "Nueva conversación"), { newConversationRequested(placement) })
        )
    }

    /// Agentes persistentes de la carpeta del proyecto (último sondeo).
    var folderAgents: [PersistentAgentOverview] {
        guard let folder else { return [] }
        return store.watch.agents(serverID: handle.serverID, folder: folder)
    }
}

/// Tarjeta centrada con icono, texto y una acción opcional.
struct AgentPanelCard: View {
    let icon: String
    let tint: Color
    let title: String
    let text: String
    var action: (String, () -> Void)? = nil

    var body: some View {
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
}

/// Identidad de las acciones de pestaña del agente (ver `TabActions.identity`).
struct AgentTabIdentity: Hashable {
    let handle: SessionHandle
    let tabIDs: [UUID]
    let selectedID: UUID?
}

/// Envoltorio `Identifiable` para presentar `ClaudeSetupSheet` con `.sheet(item:)`.
struct SetupRequest: Identifiable {
    let purpose: ClaudeSetupSheet.Purpose
    var id: String {
        switch purpose {
        case .install: return "install"
        case .login: return "login"
        }
    }
}
