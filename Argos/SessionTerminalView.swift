//
//  SessionTerminalView.swift
//  Argos
//
//  Panel de detalle con el terminal en vivo de la sesión seleccionada.
//
//  - `TerminalViewRepresentable` envuelve el `TerminalView` (NSView de AppKit) de
//    SwiftTerm para usarlo en SwiftUI.
//  - `SessionTerminalView` toma el `LiveTerminalController` de la sesión del pool con
//    `.task(id:)`; las ventanas y paneles los lleva `TerminalWindowsModel` (núcleo) y la
//    reconexión automática `TerminalReconnectScheduler` con `ReconnectPolicy`.
//  - Menú «Panel», diálogos y atajos: `SessionTerminalView+Windows.swift`; barra inferior
//    y capas de estado: `TerminalStatusBar.swift` y `TerminalOverlays.swift`.
//

import SwiftUI
import SwiftTerm

// MARK: - Puente AppKit -> SwiftUI

/// Incrusta el `TerminalView` (AppKit) que posee el controlador dentro de SwiftUI.
/// Recibe `fontSize`/`theme` como propiedades para que SwiftUI invoque `updateNSView`
/// cuando cambien (los ajustes viven en `TerminalSettings`, observable).
struct TerminalViewRepresentable: NSViewRepresentable {
    let controller: LiveTerminalController
    let fontSize: Double
    let theme: TerminalTheme

    func makeNSView(context: Context) -> ArgosTerminalView {
        apply(to: controller.terminalView)
        return controller.terminalView
    }

    func updateNSView(_ nsView: ArgosTerminalView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: ArgosTerminalView) {
        let newFont = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        if view.font != newFont { view.font = newFont }
        view.applyTheme(theme)
    }
}

// MARK: - Detalle con terminal en vivo

struct SessionTerminalView: View {
    let handle: SessionHandle
    let session: TmuxSession
    let service: any SSHServicing
    /// Pool persistente: el controlador sobrevive al cambio de selección.
    let store: TerminalSessionStore
    /// Estado de Claude Code por índice de ventana (indicador en las pestañas).
    let claudeByWindow: [Int: ClaudeActivity]
    /// Carpeta del proyecto (`nil` en una sesión suelta): cabecera, rama y agentes.
    let projectPath: String?
    /// Nombre del servidor para la barra inferior.
    let serverName: String
    /// El terminal se desenganchó limpiamente (`exit` en la última shell, sesión matada
    /// desde otro cliente…): quien lista las sesiones comprueba si sigue existiendo.
    let onEnded: () -> Void
    /// El servidor dice que la sesión ya no existe: quien muestra la vista la da por
    /// detenida (el proyecto ofrece «Iniciar») en vez de reintentar.
    let onSessionMissing: () -> Void

    @State private var settings = TerminalSettings.shared
    /// Agentes instalados en el servidor (`nil` mientras no se sabe).
    @State var installedAgents: Set<CodingAgent>?
    /// Carpeta de trabajo mostrada (la del proyecto o la del primer panel).
    @State var workingPath: String?
    /// Rama git de `workingPath`, si es un repositorio.
    @State var gitBranch: String?
    @State var controller: LiveTerminalController?
    /// Ventanas y paneles de tmux (sondeo adaptativo y acciones).
    @State var windowsModel: TerminalWindowsModel
    /// Reintentos automáticos con `ReconnectPolicy` (la de iPhone/iPad y Android).
    @State private var reconnect = TerminalReconnectScheduler()
    @State var showKillPaneConfirm = false
    /// Con el Mac dormido no se sondea ni se reconecta solo (PR #2, Kevin Jovy).
    @State private var sleepMonitor = SystemSleepMonitor.shared
    /// Ventana cuyo nombre se está editando (presenta el sheet de renombrar).
    @State var renamingWindow: TmuxWindow?
    /// Ventana pendiente de confirmar su cierre.
    @State var closingWindow: TmuxWindow?
    /// Barra «Buscar en el historial» (modo copia de tmux).
    @State var search: TerminalSearchModel
    /// Aviso de «Copiar la salida del último comando».
    @State var lastOutput: TerminalLastOutputModel
    /// Marcas de prompt OSC 133 del servidor.
    @State var shellMarks: ShellIntegrationModel

    init(
        handle: SessionHandle,
        session: TmuxSession,
        service: any SSHServicing,
        store: TerminalSessionStore,
        claudeByWindow: [Int: ClaudeActivity] = [:],
        projectPath: String? = nil,
        serverName: String = "",
        onEnded: @escaping () -> Void = {},
        onSessionMissing: @escaping () -> Void = {}
    ) {
        self.handle = handle
        self.session = session
        self.service = service
        self.store = store
        self.claudeByWindow = claudeByWindow
        self.projectPath = projectPath
        self.serverName = serverName
        self.onEnded = onEnded
        self.onSessionMissing = onSessionMissing
        _windowsModel = State(initialValue: TerminalWindowsModel(service: service, sessionName: session.name))
        let runner: TerminalSearchModel.Runner = { (script: String) in try await service.runTerminalCommand(script) }
        _search = State(initialValue: TerminalSearchModel(sessionName: session.name, run: runner))
        _lastOutput = State(initialValue: TerminalLastOutputModel(run: runner))
        _shellMarks = State(initialValue: ShellIntegrationModel(service: service))
    }

    var windows: [TmuxWindow] { windowsModel.windows }
    var isConnected: Bool { controller?.status == .connected }

    var body: some View {
        VStack(spacing: 0) {
            if isConnected && !windows.isEmpty {
                WindowBar(
                    windows: windows,
                    claudeByWindow: claudeByWindow,
                    installedAgents: installedAgents,
                    onSelect: { window in run { await $0.select(window) } },
                    onNew: { run { await $0.newWindow() } },
                    onNewAgent: { newAgentWindow($0) },
                    onRename: { renamingWindow = $0 },
                    onSetColor: { window, color in run { await $0.setColor(color, for: window) } },
                    onClose: { requestClose(index: $0.index) }
                )
                Divider()
            }
            terminalCard
            TerminalStatusBar(
                serverName: serverName,
                gitBranch: gitBranch,
                workingPath: workingPath,
                agentCount: windows.filter { WindowTabs.agent(for: $0, claudeReported: claudeByWindow[$0.index] != nil) != nil }.count,
                isConnected: isConnected,
                statusText: terminalStatusText
            )
        }
        .focusedSceneValue(\.tabActions, tabActions)
        .focusedSceneValue(\.terminalFindActions, findActions)
        .navigationTitle(session.name)
        .navigationSubtitle("Terminal remoto")
        .toolbar { paneToolbar }
        .modifier(windowDialogs)
        // Toma el controlador del pool (lo crea si es la primera vez). NO lo detiene al
        // desaparecer: la conexión persiste para que volver a la sesión sea instantáneo.
        .task(id: handle) {
            let live = store.controller(for: handle, service: service, sessionName: session.name)
            // Si quedó muerto (detach limpio o error previo), reconecta al reabrir.
            switch live.status {
            case .ended, .failed:
                controller = store.reconnect(handle, service: service, sessionName: session.name)
            case .connecting, .connected:
                controller = live
            }
            installFindHandler()
        }
        // Sondea las ventanas de tmux mientras esta sesión está a la vista y conectada.
        .task(id: handle) {
            await windowsModel.poll(while: { !sleepMonitor.isAsleep && controller?.status == .connected })
        }
        .task(id: handle) { await loadAgentsAndBranch() }
        .task(id: handle) { await shellMarks.load() }
        .onChange(of: windows) { Task { await refreshBranch() } }
        // Con la identidad del controlador: un reintento que falla AL INSTANTE con el mismo
        // mensaje deja el estado igual (`.failed(msg)`), y solo por el estado no se vería.
        .onChange(of: StatusKey(controller: controller)) { _, key in handleStatusChange(key.status) }
        .onChange(of: sleepMonitor.isAsleep) { _, asleep in handleSleepChange(asleep: asleep) }
        .onDisappear {
            reconnect.cancel()
            // Que el panel no se quede en modo copia al cambiar de proyecto o sesión.
            search.dismiss()
        }
    }

    private var terminalArea: some View {
        ZStack {
            if let controller {
                TerminalViewRepresentable(
                    controller: controller,
                    fontSize: settings.fontSize,
                    theme: settings.theme
                )
                TerminalStatusOverlay(
                    status: controller.status,
                    sessionName: session.name,
                    reconnect: reconnect,
                    onReconnect: reconnectManually
                )
                if !controller.uploads.queue.isEmpty {
                    VStack {
                        TerminalUploadQueueView(model: controller.uploads)
                            .padding(.top, 12)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let error = windowsModel.actionError {
                    TerminalActionErrorBanner(message: error) { windowsModel.actionError = nil }
                }
                searchOverlay
            } else {
                TerminalConnectionProgress(title: String(localized: "Abriendo sesión"), sessionName: session.name)
            }
        }
        .animation(.snappy, value: controller?.uploads.queue.isEmpty)
    }

    // MARK: - Tarjeta del terminal (estilo herdr)

    /// El terminal dentro de una tarjeta redondeada con cabecera: icono y nombre de lo
    /// que corre en la ventana activa, más la carpeta de trabajo.
    private var terminalCard: some View {
        let theme = settings.theme
        return VStack(spacing: 0) {
            if isConnected {
                cardHeader(foreground: SwiftUI.Color(nsColor: theme.foreground))
            }
            terminalArea
        }
        .background(SwiftUI.Color(nsColor: theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isConnected ? SwiftUI.Color.accentColor.opacity(0.45) : SwiftUI.Color.primary.opacity(0.1),
                    lineWidth: 1
                )
        )
        .padding(8)
        .background(.bar)
    }

    var activeAgent: CodingAgent? {
        windowsModel.activeWindow.flatMap { WindowTabs.agent(for: $0, claudeReported: claudeByWindow[$0.index] != nil) }
    }

    private func cardHeader(foreground: SwiftUI.Color) -> some View {
        let agent = activeAgent
        let title = agent?.displayName
            ?? windowsModel.activeWindow.flatMap { WindowTabs.title(for: $0, agent: nil) }
            ?? String(localized: "Terminal")
        return HStack(spacing: 8) {
            if let agent {
                CodingAgentIcon(agent: agent, size: 12)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.7))
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
            if let workingPath {
                Text(PathDisplay.short(workingPath))
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(workingPath)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(foreground.opacity(0.08)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var terminalStatusText: String {
        guard let status = controller?.status else { return String(localized: "Preparando terminal") }
        switch status {
        case .connecting: return String(localized: "Conectando por SSH…")
        case .connected: return String(localized: "Conexión segura · SSH")
        case .ended: return String(localized: "Terminal desconectado")
        case .failed: return reconnect.isReconnecting ? String(localized: "Reconectando…") : String(localized: "Error de conexión")
        }
    }

    // MARK: - Acciones

    /// Lanza una acción de ventana o panel (su fallo queda en `windowsModel.actionError`).
    func run(_ action: @escaping @MainActor (TerminalWindowsModel) async -> Void) {
        let model = windowsModel
        Task { await action(model) }
    }

    /// Abre una ventana nueva con `agent` en la carpeta del proyecto (o la del panel).
    func newAgentWindow(_ agent: CodingAgent) {
        let directory = projectPath
        run { await $0.newAgentWindow(agent, directory: directory) }
    }

    // MARK: - Reconexión automática (`ReconnectPolicy`)

    /// Al conectar se olvida la cuenta; ante un fallo se reintenta con espera creciente
    /// salvo que haga falta el usuario (huella, credenciales). El detach limpio
    /// (`.ended`) NO se reconecta solo (la sesión pudo cerrarse).
    private func handleStatusChange(_ status: LiveTerminalStatus?) {
        switch status {
        case .connected:
            reconnect.didConnect()
        case .failed:
            if controller?.lastError is TerminalSessionMissingError {
                reconnect.cancel()
                onSessionMissing()
                return
            }
            reconnect.didFail(controller?.lastError, isAsleep: sleepMonitor.isAsleep, reconnect: reconnectNow)
        case .ended:
            onEnded()
        default:
            break
        }
    }

    /// Reposo del Mac: al dormir cancela el reintento pendiente; al despertar, si el
    /// terminal cayó, vuelve a intentarlo desde cero.
    private func handleSleepChange(asleep: Bool) {
        if asleep {
            reconnect.willSleep()
        } else {
            reconnect.didWake(
                terminalFailed: TerminalSleepPolicy.reconnectsOnWake(controller?.status),
                lastError: controller?.lastError,
                reconnect: reconnectNow
            )
        }
    }

    private func reconnectNow() {
        controller = store.reconnect(handle, service: service, sessionName: session.name)
        installFindHandler()
    }

    /// «Reconectar» del banner: acción explícita, levanta también el bloqueo de la
    /// conexión (credenciales o host key) que la reconexión automática respeta.
    private func reconnectManually() {
        let service = self.service
        reconnect.reconnectNow {
            await service.resetConnectionHealth()
            reconnectNow()
        }
    }
}

/// Estado del terminal junto con QUÉ controlador lo tiene (ver `onChange` del estado).
private struct StatusKey: Equatable {
    let controllerID: ObjectIdentifier?
    let status: LiveTerminalStatus?

    @MainActor
    init(controller: LiveTerminalController?) {
        controllerID = controller.map(ObjectIdentifier.init)
        status = controller?.status
    }
}
