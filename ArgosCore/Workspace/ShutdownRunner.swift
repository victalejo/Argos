//
//  ShutdownRunner.swift
//  ArgosCore
//
//  Cierre ordenado con plazo: si un paso se cuelga (una conexión medio abierta que no
//  atiende a la cancelación), quien sale no espera más que `timeout`.
//

import Foundation

enum ShutdownRunner {
    /// Ejecuta `steps` y devuelve `true` si terminaron antes de `timeout`. Si el plazo
    /// vence, devuelve `false` SIN esperar a que acaben (ver `Deadline`).
    @discardableResult
    static func run(within timeout: Duration, _ steps: @escaping @Sendable () async -> Void) async -> Bool {
        let finished = await Deadline.succeeds(within: timeout) {
            await steps()
            return true
        }
        if !finished { Log.store.notice("Salida: el cierre ordenado no terminó a tiempo.") }
        return finished
    }
}
