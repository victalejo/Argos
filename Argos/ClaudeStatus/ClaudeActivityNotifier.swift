//
//  ClaudeActivityNotifier.swift
//  Argos
//
//  Notificaciones de macOS cuando Claude Code termina o espera respuesta en una
//  sesión. Solo con la app en segundo plano: en primer plano basta el indicador de
//  la barra lateral (evita ruido mientras el usuario ya está mirando).
//

import AppKit
import UserNotifications

@MainActor
final class ClaudeActivityNotifier {
    static let shared = ClaudeActivityNotifier()

    private var hasRequestedAuthorization = false

    private init() {}

    func notify(serverName: String, transitions: [ClaudeTransition]) {
        guard !transitions.isEmpty, !NSApp.isActive else { return }
        requestAuthorizationIfNeeded()
        for transition in transitions {
            let content = UNMutableNotificationContent()
            content.title = transition.activity.label
            content.subtitle = "\(transition.session) · \(serverName)"
            content.body = transition.activity == .waiting
                ? "Necesita permiso o una respuesta para continuar."
                : "Terminó de responder."
            content.sound = .default
            // Mismo identificador por sesión: un aviso nuevo reemplaza al anterior.
            let request = UNNotificationRequest(
                identifier: "claude-\(serverName)-\(transition.session)",
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

    /// Pide permiso de notificaciones (una vez). Se llama al detectar actividad de
    /// Claude por primera vez, ANTES de necesitar notificar (la petición es asíncrona).
    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                Log.terminal.error("Permiso de notificaciones: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
