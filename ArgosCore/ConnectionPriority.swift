//
//  ConnectionPriority.swift
//  ArgosCore
//
//  Quién pide la red: el usuario (una acción explícita, que no debe esperar) o un sondeo
//  de fondo (estado de Claude, git, CI, puertos…, que puede esperar y no debe insistir
//  contra un servidor caído). Viaja como valor de tarea (`@TaskLocal`): marcar un punto de
//  entrada de fondo basta para que TODO lo que hace por debajo —incluida la conexión y el
//  turno de canal en `SSHService`— se trate como fondo, sin pasar parámetros.
//
//  Uso para un sondeo nuevo:
//
//      let fresh = try await ConnectionPriority.background {
//          try await service.algoQueSeSondea()
//      }
//
//  Lo no marcado cuenta como acción del usuario (el valor por defecto).
//

import Foundation

enum ConnectionPriority: Sendable, Hashable {
    /// Acción del usuario: se salta la espera entre reintentos y tiene turno preferente.
    case user
    /// Sondeo de fondo: respeta la espera exponencial y tiene un cupo de canales menor.
    case background

    /// Prioridad de la tarea actual (`.user` si nadie la marcó).
    @TaskLocal static var current: ConnectionPriority = .user

    /// Ejecuta `operation` como trabajo de fondo (en el mismo contexto que quien llama).
    nonisolated(nonsending) static func background<T>(
        _ operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $current.withValue(.background, operation: operation)
    }
}
