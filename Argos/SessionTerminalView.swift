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
struct TerminalViewRepresentable: NSViewRepresentable {
    let controller: LiveTerminalController

    func makeNSView(context: Context) -> TerminalView {
        controller.terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // El estado lo gestiona el controlador; nada que sincronizar aquí.
    }
}

// MARK: - Detalle con terminal en vivo

struct SessionTerminalView: View {
    let session: TmuxSession
    let service: any SSHServicing

    @State private var controller: LiveTerminalController?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let controller {
                TerminalViewRepresentable(controller: controller)
                    .ignoresSafeArea()
                overlay(for: controller.status)
            } else {
                ProgressView("Abriendo terminal…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.name)
        .navigationSubtitle("tmux attach")
        // Reabre el terminal al cambiar de sesión o al reintentar. La cancelación de
        // esta `.task` (cambio de id / desaparición de la vista) dispara el detach.
        .task(id: "\(session.id)#\(attempt)") {
            let controller = LiveTerminalController(service: service, sessionName: session.name)
            self.controller = controller
            defer {
                controller.stop()
                self.controller = nil
            }
            await Self.waitUntilCancelled()
        }
    }

    // MARK: - Overlays de estado

    @ViewBuilder
    private func overlay(for status: LiveTerminalStatus) -> some View {
        switch status {
        case .connecting:
            ProgressView("Conectando a la sesión…")
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

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
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "No se pudo abrir el terminal",
                message: message
            )
        }
    }

    /// Banner inferior con acción de reconexión.
    private func banner(icon: String, tint: SwiftUI.Color, title: String, message: String) -> some View {
        VStack {
            Spacer()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reconectar") { attempt += 1 }
                    .buttonStyle(.borderedProminent)
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
