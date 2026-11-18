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

    /// Resultado de `operation` si termina antes de `timeout`. Si el plazo vence, se
    /// cancela `operation` y se lanza `timeoutError()` SIN esperar a que acabe (una
    /// operación de red colgada puede no atender la cancelación). Si se cancela a quien
    /// llama, lanza `CancellationError`.
    static func value<T: Sendable>(
        within timeout: Duration,
        timeoutError: @escaping @Sendable () -> Error,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (results, continuation) = AsyncStream<Result<T, Error>>.makeStream()
        let work = Task {
            do {
                continuation.yield(.success(try await operation()))
            } catch {
                continuation.yield(.failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(.failure(timeoutError()))
            } catch {
                // Cancelado: la operación llegó antes.
            }
        }
        defer {
            work.cancel()
            timer.cancel()
            continuation.finish()
        }
        // `AsyncStream` termina sola si se cancela a quien espera.
        for await result in results { return try result.get() }
        throw CancellationError()
    }
}
