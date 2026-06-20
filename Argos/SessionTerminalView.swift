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

    @State private var settings = TerminalSettings.shared
    @State private var controller: LiveTerminalController?
    /// Ventanas de tmux de la sesión (barra superior).
    @State private var windows: [TmuxWindow] = []
    /// Nº de reconexiones automáticas consecutivas (se resetea al conectar).
    @State private var autoReconnectCount = 0
    @State private var isAutoReconnecting = false
    @State private var reconnectTask: Task<Void, Never>?

    /// Tope de reintentos automáticos antes de mostrar el banner manual.
    private static let maxAutoReconnects = 5

    var body: some View {
        VStack(spacing: 0) {
            if controller?.status == .connected && !windows.isEmpty {
                WindowBar(
                    windows: windows,
                    onSelect: { selectWindow($0) },
                    onNew: { newWindow() }
                )
                Divider()
            }
            terminalArea
        }
        .navigationTitle(session.name)
        .navigationSubtitle("tmux attach")
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
            windows = (try? await service.listWindows(session: session.name)) ?? windows
        }
    }

    private func newWindow() {
        Task {
            try? await service.newWindow(session: session.name)
            windows = (try? await service.listWindows(session: session.name)) ?? windows
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
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.4)
                VStack(spacing: 6) {
                    Text("Abriendo sesión")
                        .font(.title3.weight(.medium))
                    Text(session.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
        }
    }

    // MARK: - Overlays de estado

    @ViewBuilder
    private func overlay(for status: LiveTerminalStatus) -> some View {
        switch status {
        case .connecting:
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                VStack(spacing: 20) {
                    ProgressView()
                        .controlSize(.large)
                        .scaleEffect(1.4)
                    VStack(spacing: 6) {
                        Text("Conectando a la sesión")
                            .font(.title3.weight(.medium))
                        Text(session.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                }
            }
            .transition(.opacity.animation(.easeOut(duration: 0.25)))

        case .connected:
            EmptyView()

        case .ended:
            banner(
                icon: "bolt.horizontal.circle",
                tint: .secondary,
                title: "Sesión desconectada",
                message: "Te desenganchaste de la sesión (sigue viva en el servidor)."
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
    }

}

// MARK: - Barra de ventanas de tmux

struct WindowBar: View {
    let windows: [TmuxWindow]
    let onSelect: (TmuxWindow) -> Void
    let onNew: () -> Void

    /// Etiqueta de VoiceOver de una pestaña de ventana: índice, nombre, si está activa
    /// y cuántos paneles tiene (el botón se expone con texto, no solo con color/forma).
    static func accessibilityLabel(for window: TmuxWindow) -> String {
        var parts = ["Ventana \(window.index): \(window.name)"]
        if window.isActive { parts.append("activa") }
        if window.paneCount > 1 { parts.append("\(window.paneCount) paneles") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(windows) { window in
                    Button { onSelect(window) } label: {
                        HStack(spacing: 5) {
                            Text("\(window.index)")
                                .font(.caption.monospaced())
                                .foregroundStyle(window.isActive ? Color.accentColor : .secondary)
                            Text(window.name)
                                .font(.callout)
                                .lineLimit(1)
                            if window.paneCount > 1 {
                                Image(systemName: "rectangle.split.2x1")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            window.isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(window.isActive ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Cambiar a la ventana \(window.index): \(window.name)")
                    .accessibilityLabel(Self.accessibilityLabel(for: window))
                }

                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help("Nueva ventana")
                .accessibilityLabel("Nueva ventana")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}
