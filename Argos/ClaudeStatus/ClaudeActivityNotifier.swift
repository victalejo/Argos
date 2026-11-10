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

    private override init() {
        super.init()
        // Sin delegado, macOS NO muestra las notificaciones con la app en primer plano.
        UNUserNotificationCenter.current().delegate = self
    }

    /// `viewing`: sesión abierta en pantalla en ese servidor (si la hay).
    /// - Parameter gitSummary: resumen git del proyecto de una sesión, para que el aviso
    ///   de «terminó» diga cuántos archivos hay cambiados.
    func notify(
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
            content.subtitle = "\(transition.session) · ventana \(transition.window) · \(serverName)"
            content.body = transition.activity == .waiting
                ? "Necesita permiso o una respuesta para continuar."
                : ClaudeDoneMessage.body(changedFiles: gitSummary(transition.session)?.changedCount)
            content.sound = .default
            content.threadIdentifier = "claude-\(serverName)-\(transition.session)"
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
    func notifyCI(_ results: [CIResult], serverName: String) {
        guard !results.isEmpty else { return }
        requestAuthorizationIfNeeded()
        for result in results {
            let content = UNMutableNotificationContent()
            content.title = result.title
            content.subtitle = serverName
            content.body = result.body
            content.sound = .default
            content.threadIdentifier = "ci-\(serverName)-\(result.watch.root)"
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
}
