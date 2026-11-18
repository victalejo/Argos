//
//  DeadlineValue.swift
//  ArgosCore
//
//  Variante de `Deadline.succeeds` que devuelve el resultado de la operación (o `nil` si
//  vence el plazo). Igual que aquella, NO espera a una operación colgada que no atienda
//  la cancelación.
//

import Foundation

extension Deadline {

    /// El valor de `operation` si llega antes de `timeout`; si no, `nil` (y se cancela
    /// `operation` sin esperarla).
    static func value<Value: Sendable>(
        within timeout: Duration,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let (results, continuation) = AsyncStream<Value?>.makeStream()
        let work = Task { continuation.yield(await operation()) }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(nil)
            } catch {
                // Cancelado: la operación llegó antes.
            }
        }
        defer {
            work.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await result in results { return result }
        return nil
    }
}
