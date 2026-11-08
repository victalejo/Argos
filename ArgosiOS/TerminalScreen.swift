//
//  TerminalScreen.swift
//  ArgosiOS
//
//  Terminal en vivo de una sesión tmux. Arriba, las ventanas de la sesión como
//  pestañas (`TerminalWindowBar`: terminal o agente, menú «+»); debajo, una cabecera
//  con lo que corre y la carpeta, y el `TerminalView` de SwiftTerm, que trae su propia
//  barra de teclas (esc, ctrl, tab, flechas) sobre el teclado. En el iPad, además, una
//  barra inferior (servidor · rama · agentes) y atajos de teclado físico (⌘T, ⌘W,
//  ⌘1…⌘9, ⌘⇧[ / ⌘⇧]).
//

import SwiftTerm
import SwiftUI

struct TerminalScreen: View {
    let server: Server
    let sessionName: String
    /// Carpeta del proyecto (`nil` en una sesión suelta): agentes, cabecera y rama.
    var projectPath: String?

    @Environment(ServerHub.self) private var hub
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage(TerminalAppearance.fontSizeKey) private var fontSize = Double(TerminalAppearance.defaultFontSize)
    @State private var windows: [TmuxWindow] = []
    /// Lo crea `onAppear` (nunca `body`): crear el terminal abre una conexión, y hacerlo
    /// durante el render podría resucitar uno ya cerrado al salir de la pantalla.
    @State private var controller: TouchTerminalController?
    /// Agentes instalados en el servidor (`nil` mientras no se sabe).
    @State private var installedAgents: Set<CodingAgent>?
    /// Ventana pendiente de confirmar su cierre (corre algo en ella).
    @State private var closingWindow: TmuxWindow?
    @State private var workingPath: String?
    @State private var gitBranch: String?
    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    @State private var isShowingText = false

    /// Cada cuánto se releen las ventanas mientras el terminal está a la vista (para
    /// ver qué corre en cada una: agentes, shell ocioso…).
    private static let pollInterval: Duration = .seconds(4)
    /// Tope del espaciado de reintentos cuando el servidor no responde.
    private static let maxPollInterval: Duration = .seconds(60)

    private var service: any SSHServicing { hub.viewModel(for: server).service }

    var body: some View {
        VStack(spacing: 0) {
            if !windows.isEmpty {
                TerminalWindowBar(
                    windows: windows,
                    claudeWindows: claudeWindows,
                    installedAgents: installedAgents,
                    onSelect: select,
                    onNew: newWindow,
                    onNewAgent: newAgentWindow,
                    onClose: { requestClose(index: $0.index) }
                )
                header
            }
            if let controller {
                TerminalHost(view: controller.terminalView)
                    .id(ObjectIdentifier(controller))
                    .overlay { statusOverlay(controller) }
            } else {
                Color(white: 0.07)
            }
            if sizeClass == .regular && !windows.isEmpty {
                bottomBar
            }
        }
        .background(Color(white: 0.07))
        .background { keyboardShortcuts }
        .modifier(TerminalInputActions(
            controller: controller,
            isPickingPhotos: $isPickingPhotos,
            isPickingFiles: $isPickingFiles,
            isShowingText: $isShowingText
        ))
        .confirmationDialog(
            "¿Cerrar la ventana \(closingWindow?.index ?? 0)?",
            isPresented: Binding(get: { closingWindow != nil }, set: { if !$0 { closingWindow = nil } }),
            titleVisibility: .visible,
            presenting: closingWindow
        ) { window in
            Button("Cerrar ventana", role: .destructive) { close(window) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Se cerrarán sus paneles y se perderá lo que corra en ellos.")
        }
        .navigationTitle(sessionName)
        .navigationBarTitleDisplayMode(.inline)
        // Barra oscura a juego con el terminal (si no, el título no se lee).
        .toolbarBackground(Color(white: 0.11), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { toolbar }
        // Solo sondea con la app activa: al pasar a segundo plano la tarea se cancela y
        // al volver arranca de nuevo (relee al instante).
        .task(id: PollKey(session: sessionName, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            await pollWindows()
        }
        .task(id: sessionName) { await loadAgentsAndBranch() }
        .onChange(of: windows) {
            if sizeClass == .regular { Task { await refreshBranch() } }
        }
        .onChange(of: fontSize) { _, size in
            controller?.terminalView.font = TerminalAppearance.font(size: CGFloat(size))
        }
        .onAppear {
            if controller == nil { controller = hub.terminal(for: server, sessionName: sessionName) }
        }
        .onDisappear {
            hub.closeTerminal(server: server.id, sessionName: sessionName)
            controller = nil
        }
    }

    // MARK: - Cabecera y barra inferior

    private var claudeWindows: Set<Int> {
        Set(hub.viewModel(for: server).claudeActivity.windows(forSession: sessionName).keys)
    }

    private var activeAgent: CodingAgent? {
        windows.first { $0.isActive }.flatMap {
            WindowTabs.agent(for: $0, claudeReported: claudeWindows.contains($0.index))
        }
    }

    /// Cabecera fina: icono y nombre de lo que corre en la ventana activa + carpeta.
    private var header: some View {
        let agent = activeAgent
        let title = agent?.displayName
            ?? windows.first { $0.isActive }.flatMap { WindowTabs.title(for: $0, agent: nil) }
            ?? "Terminal"
        return HStack(spacing: 7) {
            if let agent {
                CodingAgentIcon(agent: agent, size: 11)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            if let workingPath {
                Text(PathDisplay.short(workingPath))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(white: 0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    /// Barra inferior del iPad: servidor · rama git · agentes activos.
    private var bottomBar: some View {
        let agents = windows.filter {
            WindowTabs.agent(for: $0, claudeReported: claudeWindows.contains($0.index)) != nil
        }.count
        return HStack(spacing: 14) {
            Label(server.name, systemImage: "server.rack")
            if let gitBranch {
                Label(gitBranch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if agents > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Color.teal).frame(width: 6, height: 6)
                    Text("\(agents) \(agents == 1 ? "agente" : "agentes")")
                }
            }
            Spacer(minLength: 8)
            Text("⌘T nueva · ⌘W cerrar · ⌘1…9")
                .font(.caption2)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.11))
    }

    /// Atajos de teclado físico (iPad): botones invisibles con `.keyboardShortcut`.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Nueva ventana", action: newWindow)
                .keyboardShortcut("t", modifiers: .command)
            Button("Cerrar ventana") { requestClose(index: nil) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Pestaña anterior") { selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Pestaña siguiente") { selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Última pestaña" : "Pestaña \(number)") {
                    if let target = WindowTabs.window(atShortcut: number, in: windows) { select(target) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            ForEach(CodingAgent.allCases) { agent in
                Button("Iniciar \(agent.displayName)") { newAgentWindow(agent) }
                    .keyboardShortcut(KeyEquivalent(agent.menuKey), modifiers: [.command, .option])
                    .disabled(!(installedAgents?.contains(agent) ?? true))
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Ventanas de tmux

    /// Relee las ventanas mientras el terminal está a la vista y la app activa. Si el
    /// servidor no responde, espacia los intentos (4→8→…→60 s) para no gastar batería
    /// ni competir con la reconexión del propio terminal.
    private func pollWindows() async {
        var interval = Self.pollInterval
        while !Task.isCancelled {
            let ok = await refreshWindows()
            interval = ok ? Self.pollInterval : min(interval * 2, Self.maxPollInterval)
            do { try await Task.sleep(for: interval) } catch { break }
        }
    }

    @discardableResult
    private func refreshWindows() async -> Bool {
        do {
            let fresh = try await service.listWindows(session: sessionName)
            if fresh != windows { windows = fresh }
            return true
        } catch {
            Log.terminal.notice("No se pudieron leer las ventanas: \(error.userMessage, privacy: .public)")
            return false
        }
    }

    private func select(_ window: TmuxWindow) {
        Task {
            try? await service.selectWindow(session: sessionName, index: window.index)
            await refreshWindows()
        }
    }

    private func selectAdjacent(_ offset: Int) {
        if let target = WindowTabs.adjacent(to: windows, offset: offset) { select(target) }
    }

    private func newWindow() {
        Task {
            try? await service.newWindow(session: sessionName)
            await refreshWindows()
        }
    }

    /// Abre una ventana con `agent` en la carpeta del proyecto (o la del panel activo).
    private func newAgentWindow(_ agent: CodingAgent) {
        Task {
            do {
                try await service.newAgentWindow(session: sessionName, agent: agent, directory: projectPath)
            } catch {
                Log.terminal.error("No se pudo lanzar \(agent.displayName, privacy: .public): \(error.userMessage, privacy: .public)")
            }
            await refreshWindows()
        }
    }

    /// Cerrar (⌘W con `index == nil`: la activa; o la pestaña): directo si es un shell
    /// ocioso, con confirmación si corre algo y nunca la última ventana (mataría la
    /// sesión). Decide con la lista recién leída de tmux, no con la del sondeo.
    private func requestClose(index: Int?) {
        Task {
            let fresh: [TmuxWindow]
            do {
                fresh = try await service.listWindows(session: sessionName)
            } catch {
                Log.terminal.error("No se pudieron leer las ventanas para cerrar: \(error.userMessage, privacy: .public)")
                return
            }
            windows = fresh
            let target = index.map { wanted in fresh.first { $0.index == wanted } } ?? fresh.first { $0.isActive }
            guard let target else { return }
            switch WindowTabs.closeDecision(for: target, totalWindows: fresh.count) {
            case .blocked: break
            case .immediate: close(target)
            case .confirm: closingWindow = target
            }
        }
    }

    private func close(_ window: TmuxWindow) {
        Task {
            do {
                try await service.killWindow(session: sessionName, index: window.index)
            } catch {
                Log.terminal.error("No se pudo cerrar la ventana: \(error.userMessage, privacy: .public)")
            }
            await refreshWindows()
        }
    }

    /// Agentes instalados (con caché por servidor), carpeta de trabajo y rama git.
    private func loadAgentsAndBranch() async {
        installedAgents = InstalledAgentsCache.agents[server.id]
        do {
            let fresh = try await service.installedCodingAgents()
            InstalledAgentsCache.agents[server.id] = fresh
            installedAgents = fresh
        } catch {
            Log.terminal.notice("No se pudo detectar qué agentes hay instalados: \(error.userMessage, privacy: .public)")
        }
        if let projectPath {
            workingPath = projectPath
        } else {
            workingPath = try? await service.sessionFirstPanePaths()[sessionName]
        }
        await refreshBranch()
    }

    /// Rama git de la carpeta (solo se muestra en el iPad; se relee al cambiar las
    /// ventanas, p. ej. tras un `checkout`).
    private func refreshBranch() async {
        guard let workingPath else { return }
        do {
            gitBranch = try await service.gitBranch(at: workingPath)
        } catch {
            Log.terminal.notice("No se pudo leer la rama git: \(error.userMessage, privacy: .public)")
        }
    }

    // MARK: - Estado y barra

    @ViewBuilder
    private func statusOverlay(_ controller: TouchTerminalController) -> some View {
        switch controller.status {
        case .connecting:
            ProgressView("Conectando…")
                .tint(.white)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.07))
        case .connected:
            EmptyView()
        case .ended:
            reconnectPanel(controller, title: "Desconectado", message: "La conexión con la sesión se cerró. La sesión sigue en el servidor.")
        case .failed(let message):
            reconnectPanel(controller, title: "Error de conexión", message: message)
        }
    }

    private func reconnectPanel(_ controller: TouchTerminalController, title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "bolt.horizontal.circle")
        } description: {
            Text(message)
        } actions: {
            Button("Reconectar") { controller.reconnect() }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Pegar", systemImage: "doc.on.clipboard") { controller?.pasteFromClipboard() }
                .disabled(controller == nil)
            Menu("Adjuntar", systemImage: "paperclip") {
                Button("Fotos", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                Button("Archivos", systemImage: "folder") { isPickingFiles = true }
            }
            .disabled(controller == nil)
            Menu("Opciones", systemImage: "ellipsis.circle") {
                Button("Seleccionar texto", systemImage: "text.cursor") { isShowingText = true }
                    .disabled(controller == nil)
                Button("Reconectar", systemImage: "arrow.clockwise") { controller?.reconnect() }
                Divider()
                Button("Texto más grande", systemImage: "textformat.size.larger") {
                    fontSize = min(fontSize + 1, 24)
                }
                Button("Texto más pequeño", systemImage: "textformat.size.smaller") {
                    fontSize = max(fontSize - 1, 8)
                }
            }
        }
    }
}

/// Incrusta el `TerminalView` (UIKit) del controlador en SwiftUI.
private struct TerminalHost: UIViewRepresentable {
    let view: TerminalView

    func makeUIView(context: Context) -> TerminalView {
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

/// Identidad de la tarea de sondeo: se reinicia al cambiar de sesión o de estado de la
/// app (activa / segundo plano).
private struct PollKey: Hashable {
    let session: String
    let active: Bool
}
