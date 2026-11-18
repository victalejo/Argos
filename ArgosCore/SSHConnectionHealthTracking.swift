//
//  SSHConnectionHealthTracking.swift
//  Argos
//
//  Aplica `ConnectionHealth` a los intentos de conexión de `SSHService` (compartida,
//  dedicadas y túneles): decide si se puede tocar la red y registra cada resultado.
//

import Foundation

extension SSHService {

    /// Salud actual (para la UI y los tests).
    var connectionHealth: ConnectionHealth { health }

    /// Acción explícita del usuario (Conectar, Reintentar, ⌘R…): olvida el bloqueo por
    /// credenciales y la espera entre reintentos, y el próximo intento va a la red.
    func resetConnectionHealth() async {
        if health != ConnectionHealth() {
            Log.ssh.notice("Salud de la conexión con \(self.configuration.host, privacy: .public) reiniciada por el usuario")
        }
        health = ConnectionHealth()
        lastBlockingError = nil
    }

    /// Lanza si ahora no se debe intentar conectar (sin tocar la red).
    func admitConnectionAttempt(now: ContinuousClock.Instant = .now) throws {
        switch health.admission(for: ConnectionPriority.current, at: now) {
        case .allowed:
            return
        case .blocked:
            throw lastBlockingError ?? SSHConnectionError.notConnected
        case .deferred(let remaining):
            throw SSHConnectionError.backingOff(retryIn: remaining, lastFailure: health.lastFailureMessage)
        }
    }

    /// Registra un intento fallido. La cancelación no cuenta.
    func recordConnectionFailure(_ error: Error, now: ContinuousClock.Instant = .now) {
        guard let kind = SSHFailureKind.classify(error) else { return }
        let message = error.userMessage
        health = health.recordingFailure(kind, message: message, at: now)
        switch kind {
        case .authentication, .hostKey:
            lastBlockingError = error
            Log.ssh.error("Conexión con \(self.configuration.host, privacy: .public) bloqueada hasta que actúe el usuario: \(message, privacy: .public)")
        case .network:
            if case .backingOff(let failures, _) = health.status {
                let wait = ConnectionHealth.backoff(afterFailures: failures)
                Log.ssh.notice("Conexión con \(self.configuration.host, privacy: .public) falló (\(failures) seguidos); el fondo espera \(wait.components.seconds) s: \(message, privacy: .public)")
            }
        }
    }
}
