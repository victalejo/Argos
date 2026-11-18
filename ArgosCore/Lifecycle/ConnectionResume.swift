//
//  ConnectionResume.swift
//  ArgosCore
//
//  Al volver de segundo plano, la conexión SSH compartida puede estar muerta (iOS la
//  congeló) sin que nadie lo sepa todavía: el latido tarda hasta 30 s en notarlo, y
//  mientras tanto cualquier operación se queda colgada. Aquí se sondea con un plazo
//  corto y, si no responde, se descarta para que la siguiente operación reconecte. Un
//  segundo sondeo (ya sobre una conexión nueva) evita mostrar un error por un fallo
//  pasajero. Lógica pura: sondeo y desconexión se inyectan.
//

import Foundation

enum ConnectionResume {
    /// Plazo de cada sondeo.
    static let probeTimeout: Duration = .milliseconds(3500)

    enum Outcome: Equatable, Sendable {
        /// La conexión que había sigue viva.
        case alive
        /// Estaba muerta; se descartó y la nueva responde.
        case reconnected
        /// Ni la vieja ni una nueva responden (el refresco mostrará el error).
        case unreachable
    }

    /// Sondea la conexión; si no responde a tiempo, la descarta y reintenta una vez.
    static func revalidate(
        timeout: Duration = probeTimeout,
        probe: @escaping @Sendable () async -> Bool,
        disconnect: @Sendable () async -> Void
    ) async -> Outcome {
        if await Deadline.succeeds(within: timeout, probe) { return .alive }
        await disconnect()
        if await Deadline.succeeds(within: timeout, probe) { return .reconnected }
        // Que la operación que muestre el error abra su propia conexión, no la colgada.
        await disconnect()
        return .unreachable
    }
}

/// ¿La app pasó DE VERDAD por segundo plano? `.inactive` (Centro de control, Face ID,
/// una alerta del sistema) no cuenta: ahí la conexión sigue viva y recargar sobra.
struct BackgroundTransitionTracker: Sendable, Equatable {
    private(set) var wasInBackground = false

    mutating func enteredBackground() { wasInBackground = true }

    /// Al volver a activa: `true` si se viene de segundo plano (y se olvida).
    mutating func becameActive() -> Bool {
        defer { wasInBackground = false }
        return wasInBackground
    }
}

/// Cuándo se olvida el destino de un aviso tocado. El plazo corre desde que la conexión
/// con su servidor se resolvió (cargada o fallida), no desde el toque: conectar tras
/// volver de segundo plano puede tardar más que el plazo entero. Con un tope absoluto
/// para no saltar a la sesión minutos después.
enum NotificationRouteExpiry {
    static let lifetimeAfterSettled: Duration = .seconds(30)
    static let maximumLifetime: Duration = .seconds(180)

    /// - Parameters:
    ///   - elapsed: tiempo desde que se tocó el aviso.
    ///   - sinceSettled: tiempo desde que la conexión se resolvió (`nil` si sigue conectando).
    static func shouldExpire(elapsed: Duration, sinceSettled: Duration?) -> Bool {
        if elapsed >= maximumLifetime { return true }
        guard let sinceSettled else { return false }
        return sinceSettled >= lifetimeAfterSettled
    }
}
