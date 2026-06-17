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
    let session: TmuxSession
    let service: any SSHServicing

    @State private var settings = TerminalSettings.shared
    @State private var controller: LiveTerminalController?
    @State private var attempt = 0
    /// Nº de reconexiones automáticas consecutivas (se resetea al conectar).
    @State private var autoReconnectCount = 0
    @State private var isAutoReconnecting = false
    @State private var reconnectTask: Task<Void, Never>?

    /// Tope de reintentos automáticos antes de mostrar el banner manual.
    private static let maxAutoReconnects = 5

    var body: some View {
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
        .navigationTitle(session.name)
        .navigationSubtitle("tmux attach")
        .task(id: "\(session.id)#\(attempt)") {
            let controller = LiveTerminalController(service: service, sessionName: session.name)
            self.controller = controller
            defer {
                controller.stop()
                self.controller = nil
            }
            await Self.waitUntilCancelled()
        }
        .onChange(of: controller?.status) { _, status in
            handleStatusChange(status)
        }
        .onDisappear {
            reconnectTask?.cancel()
            reconnectTask = nil
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
            attempt += 1 // recrea el controlador vía .task(id:)
        }
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
                    Button("Reconectar") {
                        autoReconnectCount = 0
                        reconnectTask?.cancel()
                        reconnectTask = nil
                        attempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
    }

    /// Suspende de forma cancelable hasta que la `.task` que la invoca sea cancelada.
    private static func waitUntilCancelled() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3600)) }
            catch { break } // CancellationError -> la vista se cierra / cambia de sesión.
        }
    }
}
