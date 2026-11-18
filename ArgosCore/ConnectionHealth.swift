//
//  ConnectionHealth.swift
//  ArgosCore
//
//  Salud de la conexión de un servidor (lógica pura, testeable). Decide si se puede
//  intentar abrir una conexión SSH nueva:
//
//   - Contraseña/clave rechazada o host key cambiada: NO se reintenta hasta que el
//     usuario actúe (reintentar, editar el servidor). Insistir con una contraseña mala
//     es justo lo que hace que fail2ban banee la IP.
//   - Fallo de red: los sondeos de fondo esperan 1, 2, 4… hasta 60 s entre intentos; una
//     acción del usuario se lo salta. Un éxito lo reinicia todo.
//

import Foundation
@preconcurrency import Citadel

/// Por qué falló abrir una conexión.
enum SSHFailureKind: Sendable, Equatable {
    /// El servidor rechazó la contraseña o la clave (o no hay credencial utilizable).
    case authentication
    /// La huella del servidor cambió o no se pudo leer el registro de huellas.
    case hostKey
    /// Red, servidor caído, tiempo agotado… (transitorio).
    case network

    /// Clasifica el error de un intento de conexión. `nil` = cancelado (no es un fallo).
    static func classify(_ error: Error) -> SSHFailureKind? {
        if error is CancellationError { return nil }
        if error is HostKeyMismatchError || error is HostKeyStoreUnreadableError { return .hostKey }
        if isAuthentication(error) { return .authentication }
        return .network
    }

    /// Solo los fallos que bloquean los reintentos (autenticación y host key).
    static func blocking(_ error: Error) -> SSHFailureKind? {
        guard let kind = classify(error), kind != .network else { return nil }
        return kind
    }

    private static func isAuthentication(_ error: Error) -> Bool {
        switch error {
        case let client as SSHClientError:
            return client != .channelCreationFailed
        case is AuthenticationFailed:
            return true
        case let citadel as CitadelError:
            return citadel == .unauthorized
        case let service as SSHService.SSHServiceError:
            switch service {
            case .credentialUnavailable, .keyUnreadable, .keyParseFailed: return true
            default: return false
            }
        default:
            return false
        }
    }
}

/// Estado de salud inmutable: cada evento devuelve uno nuevo.
struct ConnectionHealth: Sendable, Equatable {

    enum Status: Sendable, Equatable {
        case healthy
        /// Hasta una acción explícita del usuario (`ConnectionHealth()` de nuevo).
        case blocked(SSHFailureKind)
        /// `failures` fallos de red seguidos; el fondo no reintenta antes de `retryAt`.
        case backingOff(failures: Int, retryAt: ContinuousClock.Instant)
    }

    /// Resultado de pedir permiso para conectar.
    enum Admission: Sendable, Equatable {
        case allowed
        case blocked(SSHFailureKind)
        /// Aún no: faltan `remaining` para el próximo intento de fondo.
        case deferred(remaining: Duration)
    }

    static let initialBackoff: Duration = .seconds(1)
    static let maxBackoff: Duration = .seconds(60)

    let status: Status
    /// Mensaje del último fallo (para explicar por qué se espera).
    let lastFailureMessage: String?

    init() {
        self.init(status: .healthy, lastFailureMessage: nil)
    }

    private init(status: Status, lastFailureMessage: String?) {
        self.status = status
        self.lastFailureMessage = lastFailureMessage
    }

    /// Espera tras `failures` fallos seguidos: 1, 2, 4, 8, 16, 32, 60, 60… s.
    static func backoff(afterFailures failures: Int) -> Duration {
        let exponent = min(max(failures, 1) - 1, 16)
        let seconds = min(Int64(1) << Int64(exponent), maxBackoffSeconds)
        return .seconds(seconds)
    }

    private static let maxBackoffSeconds: Int64 = 60

    func admission(for priority: ConnectionPriority, at now: ContinuousClock.Instant) -> Admission {
        switch status {
        case .healthy:
            return .allowed
        case .blocked(let kind):
            return .blocked(kind)
        case .backingOff(_, let retryAt):
            if priority == .user || now >= retryAt { return .allowed }
            return .deferred(remaining: retryAt - now)
        }
    }

    func recordingFailure(_ kind: SSHFailureKind, message: String, at now: ContinuousClock.Instant) -> ConnectionHealth {
        switch kind {
        case .authentication, .hostKey:
            return ConnectionHealth(status: .blocked(kind), lastFailureMessage: message)
        case .network:
            let failures = previousNetworkFailures + 1
            let retryAt = now + Self.backoff(afterFailures: failures)
            return ConnectionHealth(status: .backingOff(failures: failures, retryAt: retryAt), lastFailureMessage: message)
        }
    }

    func recordingSuccess() -> ConnectionHealth {
        ConnectionHealth()
    }

    var isBlocked: Bool {
        if case .blocked = status { return true }
        return false
    }

    private var previousNetworkFailures: Int {
        if case .backingOff(let failures, _) = status { return failures }
        return 0
    }
}

/// Errores propios de la capa de conexión.
enum SSHConnectionError: LocalizedError, Equatable {
    /// Un sondeo de fondo no reintenta todavía (servidor inaccesible hace poco).
    case backingOff(retryIn: Duration, lastFailure: String?)
    /// El comando no terminó en su plazo; su turno se liberó.
    case commandTimedOut(Duration)
    /// La conexión dedicada (terminal, agente, túnel) dejó de responder y se cerró.
    case connectionLost
    /// No hay conexión abierta y la operación no debe abrir una.
    case notConnected

    var errorDescription: String? {
        switch self {
        case .backingOff(let retryIn, let lastFailure):
            let seconds = max(1, Int(retryIn.components.seconds))
            let reason = lastFailure.map { " Último error: \($0)" } ?? ""
            return "El servidor no respondió hace poco; se volverá a intentar en \(seconds) s.\(reason)"
        case .commandTimedOut(let limit):
            return "El comando remoto no terminó en \(Int(limit.components.seconds)) s y se dejó de esperar. "
                + "El servidor puede estar muy cargado o la conexión, colgada: reintenta."
        case .connectionLost:
            return "La conexión con el servidor dejó de responder (¿cambio de red o reposo?) y se cerró. Reconectando…"
        case .notConnected:
            return "No hay conexión con el servidor."
        }
    }
}
