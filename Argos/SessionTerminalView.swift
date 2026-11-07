//
//  SessionTerminalView.swift
//  Argos
//
//  Fase 2: panel de detalle con el terminal en vivo de la sesión seleccionada.
//
//  - `TerminalViewRepresentable` envuelve el `TerminalView` (NSView de AppKit) de
//    SwiftTerm para usarlo en SwiftUI.
//  - `SessionTerminalView` crea/destruye un `LiveTerminalController` por sesión usando
//    `.task(id:)`: al cambiar de sesión o cerrarse el detail, la tarea se cancela y el
//    controlador hace detach (sin matar la sesión tmux).
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
        if view.nativeForegroundColor != theme.foreground {
            view.nativeForegroundColor = theme.foreground
        }
        if view.nativeBackgroundColor != theme.background {
            view.nativeBackgroundColor = theme.background
        }
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
    var claudeByWindow: [Int: ClaudeActivity] = [:]

    @State private var settings = TerminalSettings.shared
    @State private var controller: LiveTerminalController?
    /// Ventanas de tmux de la sesión (barra superior).
    @State private var windows: [TmuxWindow] = []
    /// Nº de reconexiones automáticas consecutivas (se resetea al conectar).
    @State private var autoReconnectCount = 0
    @State private var isAutoReconnecting = false
    @State private var reconnectTask: Task<Void, Never>?
    @State private var showKillPaneConfirm = false
    /// Ventana cuyo nombre se está editando (presenta el sheet de renombrar).
    @State private var renamingWindow: TmuxWindow?
    /// Ventana pendiente de confirmar su cierre.
    @State private var closingWindow: TmuxWindow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tope de reintentos automáticos antes de mostrar el banner manual.
    private static let maxAutoReconnects = 5

    var body: some View {
        VStack(spacing: 0) {
            if controller?.status == .connected && !windows.isEmpty {
                WindowBar(
                    windows: windows,
                    claudeByWindow: claudeByWindow,
                    onSelect: { selectWindow($0) },
                    onNew: { newWindow() },
                    onRename: { renamingWindow = $0 },
                    onSetColor: { setColor($1, for: $0) },
                    onClose: { closingWindow = $0 }
                )
                Divider()
            }
            terminalArea
            terminalStatusBar
        }
        .navigationTitle(session.name)
        .navigationSubtitle("Terminal remoto")
        .toolbar { paneToolbar }
        .sheet(item: $renamingWindow) { window in
            SessionNameSheet(mode: .renameWindow(current: window.name)) { newName in
                try await service.renameWindow(session: session.name, index: window.index, to: newName)
                await refreshWindows()
            }
        }
        .confirmationDialog(
            "¿Cerrar el panel activo?",
            isPresented: $showKillPaneConfirm,
            titleVisibility: .visible
        ) {
            Button("Cerrar panel", role: .destructive) { killPane() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se cerrará el panel activo y se perderá lo que corra en él.")
        }
        .confirmationDialog(
            "¿Cerrar la ventana \(closingWindow?.index ?? 0): \(closingWindow?.name ?? "")?",
            isPresented: Binding(
                get: { closingWindow != nil },
                set: { if !$0 { closingWindow = nil } }
            ),
            titleVisibility: .visible,
            presenting: closingWindow
        ) { window in
            Button("Cerrar ventana", role: .destructive) { closeWindow(window) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Se cerrarán sus paneles y se perderá lo que corra en ellos.")
        }
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
        }
        // Sondea las ventanas de tmux mientras esta sesión está a la vista.
        .task(id: handle) { await pollWindows() }
        .onChange(of: controller?.status) { _, status in
            handleStatusChange(status)
        }
        .onDisappear {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    /// Menú "Panel" en la toolbar del detalle: divide, navega, hace zoom o cierra el
    /// panel activo de tmux sin teclear el prefijo. Deshabilitado mientras no hay conexión.
    @ToolbarContentBuilder
    private var paneToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { splitPane(vertical: false) } label: {
                    Label("Dividir a la derecha", systemImage: "rectangle.split.2x1")
                }
                Button { splitPane(vertical: true) } label: {
                    Label("Dividir abajo", systemImage: "rectangle.split.1x2")
                }
                Divider()
                Button { selectPane(.left) } label: { Label("Panel a la izquierda", systemImage: "arrow.left") }
                Button { selectPane(.right) } label: { Label("Panel a la derecha", systemImage: "arrow.right") }
                Button { selectPane(.up) } label: { Label("Panel de arriba", systemImage: "arrow.up") }
                Button { selectPane(.down) } label: { Label("Panel de abajo", systemImage: "arrow.down") }
                Divider()
                Button { zoomPane() } label: {
                    Label("Zoom del panel", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(role: .destructive) { showKillPaneConfirm = true } label: {
                    Label("Cerrar panel", systemImage: "xmark.rectangle")
                }
                .disabled(!activeWindowHasMultiplePanes)
            } label: {
                Label("Panel", systemImage: "rectangle.split.2x2")
            }
            .menuIndicator(.hidden)
            .disabled(controller?.status != .connected)
            .help("Acciones de panel de tmux (dividir, navegar, zoom, cerrar)")
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
                overlay(for: controller.status)
                if controller.isUploading {
                    uploadIndicator
                }
            } else {
                connectingScreen
            }
        }
    }

    private var terminalStatusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(controller?.status == .connected ? Color.teal : Color.secondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(terminalStatusText)
                .font(.caption.weight(.medium))
            if !windows.isEmpty {
                Text("·")
                Text("\(windows.count) \(windows.count == 1 ? "ventana" : "ventanas")")
                    .font(.caption)
            }
            Spacer(minLength: 8)
            Text("⌘V pegar · Arrastra archivos para subir")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var terminalStatusText: String {
        guard let status = controller?.status else { return "Preparando terminal" }
        switch status {
        case .connecting: return "Conectando por SSH…"
        case .connected: return "Conexión segura · SSH"
        case .ended: return "Terminal desconectado"
        case .failed: return isAutoReconnecting ? "Reconectando…" : "Error de conexión"
        }
    }

    // MARK: - Ventanas de tmux

    /// Sondea las ventanas mientras la sesión está conectada, para reflejar ventanas
    /// creadas/renombradas o cambios de la activa desde el propio tmux.
    ///
    /// Adaptativo: tras un sondeo sin cambios el intervalo crece (3→6→12s) para no gastar
    /// round-trips en idle; ante un cambio vuelve a 3s. Además solo reasigna `windows` si
    /// difiere, evitando re-renders innecesarios de la barra.
    private func pollWindows() async {
        let minInterval: Duration = .seconds(3)
        let maxInterval: Duration = .seconds(12)
        var interval = minInterval
        while !Task.isCancelled {
            if controller?.status == .connected,
               let fresh = try? await service.listWindows(session: session.name) {
                if fresh != windows {
                    windows = fresh
                    interval = minInterval          // hubo cambios → sondea rápido de nuevo
                } else {
                    interval = min(interval * 2, maxInterval)  // sin cambios → ralentiza
                }
            }
            do { try await Task.sleep(for: interval) } catch { break }
        }
    }

    private func selectWindow(_ window: TmuxWindow) {
        Task {
            try? await service.selectWindow(session: session.name, index: window.index)
            await refreshWindows()
        }
    }

    private func newWindow() {
        Task {
            try? await service.newWindow(session: session.name)
            await refreshWindows()
        }
    }

    private func closeWindow(_ window: TmuxWindow) {
        Task {
            do {
                try await service.killWindow(session: session.name, index: window.index)
            } catch {
                Log.terminal.error("No se pudo cerrar la ventana: \(error.userMessage, privacy: .public)")
            }
            await refreshWindows()
        }
    }

    private func setColor(_ color: WindowColor?, for window: TmuxWindow) {
        Task {
            do {
                try await service.setWindowColor(session: session.name, index: window.index, color: color)
            } catch {
                Log.terminal.error("No se pudo cambiar el color de la ventana: \(error.userMessage, privacy: .public)")
            }
            await refreshWindows()
        }
    }

    /// Vuelve a leer las ventanas tras una acción (helper único reutilizado por las
    /// acciones de ventana y de panel).
    private func refreshWindows() async {
        windows = (try? await service.listWindows(session: session.name)) ?? windows
    }

    // MARK: - Paneles de tmux

    /// ¿La ventana activa tiene más de un panel? (Para no ofrecer "Cerrar panel" cuando
    /// cerraría la ventana entera —o la sesión, si es la última—.)
    private var activeWindowHasMultiplePanes: Bool {
        (windows.first { $0.isActive }?.paneCount ?? 1) > 1
    }

    private func splitPane(vertical: Bool) {
        Task {
            try? await service.splitPane(session: session.name, vertical: vertical)
            await refreshWindows()
        }
    }

    private func selectPane(_ direction: TmuxPaneDirection) {
        Task { try? await service.selectPane(session: session.name, direction: direction) }
    }

    private func zoomPane() {
        Task { try? await service.zoomPane(session: session.name) }
    }

    private func killPane() {
        Task {
            try? await service.killPane(session: session.name)
            await refreshWindows()
        }
    }

    // MARK: - Reconexión automática

    /// Reacciona a cambios de estado: al conectar resetea el contador; ante un fallo
    /// (error de red/SSH) reintenta con backoff exponencial hasta `maxAutoReconnects`.
    /// El detach limpio (`.ended`) NO se reconecta solo (la sesión pudo cerrarse).
    private func handleStatusChange(_ status: LiveTerminalStatus?) {
        switch status {
        case .connected:
            autoReconnectCount = 0
            isAutoReconnecting = false
            reconnectTask?.cancel()
            reconnectTask = nil
        case .failed:
            guard autoReconnectCount < Self.maxAutoReconnects, reconnectTask == nil else { return }
            scheduleAutoReconnect()
        default:
            break
        }
    }

    private func scheduleAutoReconnect() {
        let delaySeconds = min(pow(2.0, Double(autoReconnectCount)), 16) // 1,2,4,8,16
        isAutoReconnecting = true
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            autoReconnectCount += 1
            reconnectTask = nil
            controller = store.reconnect(handle, service: service, sessionName: session.name)
        }
    }

    /// Reconexión manual (botón del banner): resetea el backoff y recrea el controlador.
    private func reconnectManually() {
        autoReconnectCount = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        controller = store.reconnect(handle, service: service, sessionName: session.name)
    }

    // MARK: - Indicador de subida (imagen pegada o archivos soltados)

    private var uploadIndicator: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Subiendo al servidor…").font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 12)
            Spacer()
        }
    }

    // MARK: - Pantalla de carga inicial (antes de que exista el controlador)

    private var connectingScreen: some View {
        connectionProgress(title: "Abriendo sesión")
    }

    private func connectionProgress(title: String) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 22) {
                Image(systemName: "terminal")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(session.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                ProgressView().controlSize(.small)
                Text("Tu espacio de trabajo estará listo en un momento.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
        }
    }

    // MARK: - Overlays de estado

    @ViewBuilder
    private func overlay(for status: LiveTerminalStatus) -> some View {
        switch status {
        case .connecting:
            connectionProgress(title: "Conectando a la sesión")
                .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.25)))

        case .connected:
            EmptyView()

        case .ended:
            banner(
                icon: "bolt.horizontal.circle",
                tint: .secondary,
                title: "Sesión desconectada",
                message: "La sesión sigue abierta en el servidor. Reconecta para continuar."
            )

        case .failed(let message):
            if isAutoReconnecting {
                banner(
                    icon: "arrow.clockwise.circle",
                    tint: .secondary,
                    title: "Reconectando… (intento \(autoReconnectCount + 1) de \(Self.maxAutoReconnects))",
                    message: "Se perdió la conexión. Reintentando automáticamente.",
                    showsReconnect: false
                )
            } else {
                banner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "No se pudo abrir el terminal",
                    message: message
                )
            }
        }
    }

    /// Banner inferior con acción de reconexión opcional.
    private func banner(
        icon: String,
        tint: SwiftUI.Color,
        title: String,
        message: String,
        showsReconnect: Bool = true
    ) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .top, spacing: 12) {
                if showsReconnect {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .font(.title3)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if showsReconnect {
                    Button("Reconectar") { reconnectManually() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.18)))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
            .padding(16)
        }
    }

}
