//
//  ReconnectPolicy.swift
//  ArgosCore
//
//  Reintentos automáticos del terminal en vivo cuando la conexión se cae: espera
//  exponencial con tope (1-2-4-8-15-30 s, como `ReconnectPolicy.kt` de Android) y sin
//  reintentar cuando el fallo exige que el usuario haga algo (huella del servidor,
//  credenciales, clave ilegible). Lógica pura, para que el Mac la adopte también.
//

import Citadel
import Foundation

struct ReconnectPolicy: Sendable, Equatable {
    /// Esperas entre intentos; la última se repite hasta `maxAttempts`.
    let delays: [Duration]
    /// Reintentos automáticos seguidos antes de dejarlo en manos del usuario.
    let maxAttempts: Int

    static let standard = ReconnectPolicy(
        delays: [1, 2, 4, 8, 15, 30].map { .seconds($0) },
        maxAttempts: 8
    )

    init(delays: [Duration], maxAttempts: Int) {
        precondition(!delays.isEmpty, "Hace falta al menos una espera")
        self.delays = delays
        self.maxAttempts = max(0, maxAttempts)
    }

    /// Espera antes del reintento número `attempt` (0 = primer reintento).
    func delay(forAttempt attempt: Int) -> Duration {
        delays[min(max(attempt, 0), delays.count - 1)]
    }

    /// Qué hacer tras el fallo número `attempt` (0 = el primero desde que conectó bien).
    func decision(after error: Error, attempt: Int) -> Decision {
        guard Self.isRetryable(error) else { return .giveUp(.needsUserAction) }
        guard attempt < maxAttempts else { return .giveUp(.attemptsExhausted) }
        return .retry(after: delay(forAttempt: attempt))
    }

    enum Decision: Equatable, Sendable {
        case retry(after: Duration)
        case giveUp(GiveUpReason)
    }

    enum GiveUpReason: Equatable, Sendable {
        /// Huella cambiada, credenciales o clave: reintentar no lo arregla.
        case needsUserAction
        /// Demasiados intentos seguidos: el usuario decide («Reconectar»).
        case attemptsExhausted
    }

    /// ¿Tiene sentido reintentar solo? No si el fallo exige una acción del usuario.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is HostKeyMismatchError, is HostKeyStoreUnreadableError,
             is ImportedKeyStore.ImportError, is KeychainStore.KeychainError:
            return false
        case let ssh as SSHService.SSHServiceError:
            return isRetryable(ssh)
        case let client as SSHClientError:
            // Solo se reintenta abrir el canal; el resto son fallos de autenticación.
            return client == .channelCreationFailed
        default:
            return true
        }
    }

    private static func isRetryable(_ error: SSHService.SSHServiceError) -> Bool {
        switch error {
        case .keyUnreadable, .keyParseFailed, .credentialUnavailable, .tmuxNotInstalled:
            return false
        // `tmux attach` falla con código ≠ 0 si la sesión ya no existe: reintentar no la
        // resucita.
        case .commandFailed:
            return false
        case .installFailed, .configFailed, .uploadFailed:
            return true
        }
    }
}
