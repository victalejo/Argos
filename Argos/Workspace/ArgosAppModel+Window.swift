//
//  ArgosAppModel+Window.swift
//  Argos
//
//  La ventana principal y lo que llega de fuera de ella: un aviso tocado, un elemento de
//  la barra de menús o un comando de menú con la ventana cerrada. Antes el destino de un
//  aviso lo recogía una vista, que con la ventana cerrada ya no existía: nadie abría la
//  ventana y el destino caducaba. Ahora lo recibe el modelo, que abre la ventana.
//

import AppKit

extension ArgosAppModel {

    /// Identificador de la escena `Window` principal.
    static let mainWindowID = "main"

    /// Trae la ventana principal al frente; si está cerrada, la vuelve a abrir.
    func showMainWindow() {
        NSApp.activate()
        if let window = AppActivityProbe.mainWindows.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let windowOpener {
            windowOpener()
        } else {
            Log.store.error("No se pudo abrir la ventana principal: aún no hay quien la abra.")
        }
    }

    /// Cambiador rápido (⌘K): con la ventana delante.
    func presentQuickSwitcher() {
        showMainWindow()
        QuickSwitcher.shared.present()
    }

    // MARK: - Avisos tocados

    /// Los toques en avisos llegan aquí (también el que lanzó la app antes de arrancar).
    func connectNotificationRoutes() {
        let notifier = ClaudeActivityNotifier.shared
        notifier.routeHandler = { [weak self] route in self?.open(route) }
        if let pending = notifier.takePendingRoute() { open(pending) }
    }

    /// Lleva la ventana al servidor, la sesión en modo terminal y su ventana tmux.
    func open(_ route: NotificationRoute) {
        guard store.server(withID: route.serverID) != nil else {
            Log.store.notice("Aviso de un servidor que ya no existe: se ignora.")
            return
        }
        showMainWindow()
        selectedServerID = route.serverID
        loadSelectedIfNeeded()
        guard let name = route.session else { return }
        open(SessionHandle(serverID: route.serverID, sessionID: name), mode: .terminal)
        guard let window = route.window, let service = vms[route.serverID]?.service else { return }
        Task {
            do {
                try await service.selectWindow(session: name, index: window)
            } catch {
                Log.terminal.notice("No se pudo ir a la ventana del aviso: \(error.userMessage, privacy: .public)")
            }
        }
    }

    /// Selecciona un proyecto o sesión en el modo pedido.
    func open(_ handle: SessionHandle, mode: DetailMode) {
        selectedServerID = handle.serverID
        detailModes[handle] = mode
        selectedSession = handle
    }
}
