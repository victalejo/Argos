//
//  NotificationRouteOpener.swift
//  Argos
//
//  Abre en la ventana el destino de un aviso tocado («Claude terminó», «espera tu
//  respuesta», CI): selecciona el servidor, la sesión en modo terminal y su ventana tmux.
//

import SwiftUI

private struct NotificationRouteOpener: ViewModifier {
    @Binding var serverID: Server.ID?
    @Binding var session: SessionHandle?
    @Binding var modes: [SessionHandle: DetailMode]
    /// Servicio del servidor, si ya está conectado (para ir a la ventana del aviso).
    let service: (Server.ID) -> (any SSHServicing)?
    /// `false` si el servidor del aviso ya no existe.
    let serverExists: (Server.ID) -> Bool

    func body(content: Content) -> some View {
        content
            // El toque pudo lanzar la app: el destino espera a que exista la ventana.
            .onAppear { openPending() }
            .onReceive(NotificationCenter.default.publisher(for: ClaudeActivityNotifier.routeRequested)) { _ in
                openPending()
            }
    }

    private func openPending() {
        guard let route = ClaudeActivityNotifier.shared.takePendingRoute(), serverExists(route.serverID) else { return }
        serverID = route.serverID
        guard let name = route.session else { return }
        let handle = SessionHandle(serverID: route.serverID, sessionID: name)
        modes[handle] = .terminal
        session = handle
        guard let window = route.window, let service = service(route.serverID) else { return }
        Task {
            do {
                try await service.selectWindow(session: name, index: window)
            } catch {
                Log.terminal.notice("No se pudo ir a la ventana del aviso: \(error.userMessage, privacy: .public)")
            }
        }
    }
}

extension View {
    /// Al tocar un aviso, lleva la ventana a su servidor, sesión y ventana tmux.
    func openingNotificationRoutes(
        serverID: Binding<Server.ID?>,
        session: Binding<SessionHandle?>,
        modes: Binding<[SessionHandle: DetailMode]>,
        serverExists: @escaping (Server.ID) -> Bool,
        service: @escaping (Server.ID) -> (any SSHServicing)?
    ) -> some View {
        modifier(NotificationRouteOpener(
            serverID: serverID, session: session, modes: modes, service: service, serverExists: serverExists
        ))
    }
}
