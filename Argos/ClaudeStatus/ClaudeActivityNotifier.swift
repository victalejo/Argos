//
//  ClaudeActivityNotifier.swift
//  Argos
//
//  Notificaciones de macOS cuando Claude Code termina o espera respuesta en una
//  ventana. Se avisa siempre, salvo de la sesión que el usuario está mirando con la
//  app delante (ahí basta el indicador). Antes solo se avisaba con la app en segundo
//  plano: con Argos delante pero en otro proyecto, el aviso se perdía.
//

import AppKit
import UserNotifications

@MainActor
final class ClaudeActivityNotifier: NSObject {
    static let shared = ClaudeActivityNotifier()

    private var hasRequestedAuthorization = false

    /// Quien abre el destino de un aviso tocado (el modelo de la app, que abre la ventana
    /// aunque esté cerrada). Hasta que lo fija, el toque espera en `pendingRoute`.
    var routeHandler: ((NotificationRoute) -> Void)?
    /// Aviso tocado antes de que hubiera `routeHandler` (el toque lanzó la app).
    private var pendingRoute: (route: NotificationRoute, requestedAt: Date)?
    /// Pasado este tiempo sin nadie que lo abra, el toque se olvida.
    private static let routeLifetime: TimeInterval = 60

    func takePendingRoute(now: Date = Date()) -> NotificationRoute? {
        defer { pendingRoute = nil }
        guard let pendingRoute, now.timeIntervalSince(pendingRoute.requestedAt) < Self.routeLifetime else { return nil }
        return pendingRoute.route
    }

    /// Fija el delegado de notificaciones. Hay que llamarlo al ARRANCAR la app: si un
    /// toque en un aviso la lanza, el sistema entrega el toque enseguida y sin delegado
    /// se pierde.
    func activate() {}

    private func open(_ route: NotificationRoute) {
        if let routeHandler {
            routeHandler(route)
        } else {
            pendingRoute = (route, Date())
        }
    }

    private override init() {
        super.init()
        // Sin delegado, macOS NO muestra las notificaciones con la app en primer plano.
        UNUserNotificationCenter.current().delegate = self
    }

    /// `viewing`: sesión abierta en pantalla en ese servidor (si la hay).
    /// - Parameter gitSummary: resumen git del proyecto de una sesión, para que el aviso
    ///   de «terminó» diga cuántos archivos hay cambiados.
    func notify(
        serverID: Server.ID,
        serverName: String,
        transitions: [ClaudeTransition],
        viewing: String?,
        gitSummary: (String) -> GitRepoSummary? = { _ in nil }
    ) {
        let pending = transitions.filter { !(NSApp.isActive && $0.session == viewing) }
        guard !pending.isEmpty else { return }
        requestAuthorizationIfNeeded()
        for transition in pending {
            let content = UNMutableNotificationContent()
            content.title = transition.activity.label
            content.subtitle = String(localized: "\(transition.session) · ventana \(transition.window) · \(serverName)")
            content.body = transition.activity == .waiting
                ? String(localized: "Necesita permiso o una respuesta para continuar.")
                : ClaudeDoneMessage.body(changedFiles: gitSummary(transition.session)?.changedCount)
            content.sound = .default
            content.threadIdentifier = "claude-\(serverName)-\(transition.session)"
            content.userInfo = NotificationRoute(
                serverID: serverID, session: transition.session, window: transition.window
            ).userInfo
            // Mismo identificador por ventana: un aviso nuevo reemplaza al anterior.
            let request = UNNotificationRequest(
                identifier: "claude-\(serverName)-\(transition.session)-\(transition.window)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    Log.terminal.error("Notificación de Claude: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// «El CI de app pasó/falló» de los commits vigilados (`SessionsViewModel+CI`).
    func notifyCI(_ results: [CIResult], serverID: Server.ID, serverName: String) {
        guard !results.isEmpty else { return }
        requestAuthorizationIfNeeded()
        for result in results {
            let content = UNMutableNotificationContent()
            content.title = result.title
            content.subtitle = serverName
            content.body = result.body
            content.sound = .default
            content.threadIdentifier = "ci-\(serverName)-\(result.watch.root)"
            content.userInfo = NotificationRoute(serverID: serverID).userInfo
            let request = UNNotificationRequest(
                identifier: "ci-\(serverName)-\(result.watch.root)-\(result.watch.sha ?? "")",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    Log.terminal.error("Notificación de CI: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// «Te acercas al límite de Claude» (una vez por ventana, reinicio y nivel).
    func notifyClaudeLimit(_ alert: ClaudeLimitAlert, serverID: Server.ID, serverName: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = alert.status.title
        content.subtitle = serverName
        content.body = alert.status.message()
        content.sound = .default
        content.threadIdentifier = "claude-limits-\(serverName)"
        content.userInfo = NotificationRoute(serverID: serverID).userInfo
        let request = UNNotificationRequest(
            identifier: "claude-limits-\(serverName)-\(alert.key)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.terminal.error("Notificación de límites de Claude: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Pide permiso de notificaciones (una vez). Se llama al detectar actividad de
    /// Claude por primera vez, ANTES de necesitar notificar (la petición es asíncrona).
    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.terminal.error("Permiso de notificaciones: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Log.terminal.notice("Notificaciones de Claude desactivadas por el usuario en Ajustes del Sistema")
            }
        }
    }
}

extension ClaudeActivityNotifier: UNUserNotificationCenterDelegate {
    /// Con la app delante también se muestra (el filtro de la sesión mirada ya se aplicó).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tocar un aviso trae Argos al frente y abre su servidor, sesión y ventana.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { ClaudeActivityNotifier.shared.open(route) }
    }
}
