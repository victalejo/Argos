//
//  ChannelGate.swift
//  Argos
//
//  Tope de canales SSH simultáneos sobre la conexión compartida. OpenSSH admite
//  `MaxSessions` (10 por defecto) canales de sesión por conexión; los comandos cortos
//  (sondeos de Claude, git, puertos, latido…) y las transferencias en paralelo podían
//  coincidir y pasar de ese límite, y el servidor rechazaba el canal («no more
//  sessions» → `NIOSSHError.channelSetupRejected`). Quien llega con el cupo lleno
//  espera su turno (FIFO) en vez de fallar.
//

import Foundation

actor ChannelGate {
    /// Canales a la vez: deja margen bajo `MaxSessions` para el SFTP persistente.
    static let sharedConnectionLimit = 6

    nonisolated let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = ChannelGate.sharedConnectionLimit) {
        self.limit = max(1, limit)
    }

    var activeCount: Int { inUse }
    var waitingCount: Int { waiters.count }

    func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        // El cupo pasa directamente del que libera al que espera (inUse no cambia).
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// ¿Rechazó el servidor abrir el canal? Entonces el comando NUNCA llegó a ejecutarse
/// y reintentarlo es seguro.
enum ChannelRetry {
    static let maxAttempts = 4

    /// Espera antes del reintento `attempt` (1, 2, 3…): crece para dar tiempo a que se
    /// cierren canales.
    static func delay(forAttempt attempt: Int) -> Duration {
        .milliseconds(300 * attempt)
    }
}
