//
//  Deadline.swift
//  ArgosCore
//
//  Carrera entre una comprobación y un plazo. A diferencia de un `TaskGroup`, NO espera
//  a que la comprobación termine: una operación de red colgada (conexión medio abierta)
//  puede no atender la cancelación, y esperar por ella colgaría también a quien llama.
//

import Foundation

enum Deadline {

    /// `true` solo si `check` devuelve `true` antes de `timeout`. Si el plazo vence, se
    /// cancela `check` y se devuelve `false` sin esperar a que acabe.
    static func succeeds(
        within timeout: Duration,
        _ check: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let (results, continuation) = AsyncStream<Bool>.makeStream()
        let work = Task { continuation.yield(await check()) }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(false)
            } catch {
                // Cancelado: la comprobación llegó antes.
            }
        }
        defer {
            work.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await result in results { return result }
        return false
    }
}
