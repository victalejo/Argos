//
//  TerminalScreen.swift
//  ArgosiOS
//
//  Terminal en vivo de una sesión tmux. Arriba, las ventanas de la sesión como
//  pestañas (cambiar / crear); abajo, el `TerminalView` de SwiftTerm, que trae su
//  propia barra de teclas (esc, ctrl, tab, flechas) sobre el teclado.
//

import SwiftTerm
import SwiftUI

struct TerminalScreen: View {
    let server: Server
    let sessionName: String

    @Environment(ServerHub.self) private var hub
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TerminalAppearance.fontSizeKey) private var fontSize = Double(TerminalAppearance.defaultFontSize)
    @State private var windows: [TmuxWindow] = []
    /// Lo crea `onAppear` (nunca `body`): crear el terminal abre una conexión, y hacerlo
    /// durante el render podría resucitar uno ya cerrado al salir de la pantalla.
    @State private var controller: TouchTerminalController?

    private var service: any SSHServicing { hub.viewModel(for: server).service }

    var body: some View {
        VStack(spacing: 0) {
            if !windows.isEmpty {
                windowBar
            }
            if let controller {
                TerminalHost(view: controller.terminalView)
                    .id(ObjectIdentifier(controller))
                    .overlay { statusOverlay(controller) }
            } else {
                Color(white: 0.07)
            }
        }
        .background(Color(white: 0.07))
        .navigationTitle(sessionName)
        .navigationBarTitleDisplayMode(.inline)
        // Barra oscura a juego con el terminal (si no, el título no se lee).
        .toolbarBackground(Color(white: 0.11), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { toolbar }
        .task(id: sessionName) { await refreshWindows() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshWindows() } }
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

    // MARK: - Ventanas de tmux

    private var windowBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(windows) { window in
                    Button {
                        select(window)
                    } label: {
                        Text(verbatim: "\(window.index) \(window.name)")
                            .font(.caption.monospaced().weight(window.isActive ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                window.isActive ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.white.opacity(0.08)),
                                in: Capsule()
                            )
                    }
                    .foregroundStyle(.white)
                    .contextMenu {
                        Button("Cerrar ventana", systemImage: "xmark", role: .destructive) {
                            close(window)
                        }
                        // Cerrar la última ventana mataría la sesión entera.
                        .disabled(windows.count <= 1)
                    }
                }
                Button("Nueva ventana", systemImage: "plus", action: newWindow)
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .padding(6)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.11))
    }

    private func refreshWindows() async {
        windows = (try? await service.listWindows(session: sessionName)) ?? windows
    }

    private func select(_ window: TmuxWindow) {
        Task {
            try? await service.selectWindow(session: sessionName, index: window.index)
            await refreshWindows()
        }
    }

    private func newWindow() {
        Task {
            try? await service.newWindow(session: sessionName)
            await refreshWindows()
        }
    }

    private func close(_ window: TmuxWindow) {
        Task {
            try? await service.killWindow(session: sessionName, index: window.index)
            await refreshWindows()
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
        ToolbarItem(placement: .primaryAction) {
            Menu("Opciones", systemImage: "ellipsis.circle") {
                Button("Pegar", systemImage: "doc.on.clipboard") {
                    if let text = UIPasteboard.general.string { controller?.paste(text) }
                }
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
