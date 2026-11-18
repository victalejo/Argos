//
//  AgentStdinExchange.swift
//  Argos
//
//  Piezas puras del cliente del agente persistente: el intercambio «mando bytes por
//  stdin y espero UNA línea de respuesta» (lanzar con el token, enviar líneas grandes),
//  el estado de la conexión al log y la espera entre reintentos.
//

import Foundation

enum AgentStdinExchange {

    /// Ejecuta `command` por un canal exec, le escribe `input` por stdin y devuelve la
    /// PRIMERA línea de stdout. stdin se cierra en cuanto llega esa línea (el script ya
    /// leyó lo suyo). Si no llega ninguna, lanza el error del canal (o uno genérico).
    static func firstLine(service: any SSHServicing, command: String, input: [UInt8]) async throws -> String {
        let (stdin, writer) = AsyncStream<[UInt8]>.makeStream()
        writer.yield(input)
        let (outputStream, output) = AsyncStream<[UInt8]>.makeStream()
        let run = Task { try await service.runAgentExec(command: command, stdin: stdin, output: output) }
        var reply = ""
        for await chunk in outputStream {
            reply += String(decoding: chunk, as: UTF8.self)
            if reply.contains("\n") { break }
        }
        writer.finish()
        var channelError: Error?
        do {
            try await run.value
        } catch {
            channelError = error
        }
        if let line = reply.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty {
            return line
        }
        if let channelError {
            Log.agent.error("Sin respuesta del servidor: \(channelError.localizedDescription, privacy: .public)")
            throw channelError
        }
        throw AgentExecError(message: "El servidor no respondió.")
    }
}

/// Estado REAL de la conexión al log de un agente persistente (para la interfaz).
enum AgentLinkState: Equatable, Sendable {
    /// No se está leyendo (vista cerrada, segundo plano).
    case detached
    /// Abriendo el canal; aún no ha llegado nada.
    case connecting
    /// Leyendo el log en vivo.
    case live
    /// El flujo se cortó: se reintenta solo (`attempt` empieza en 1).
    case reconnecting(attempt: Int)

    var isLive: Bool { self == .live }
}

/// Espera exponencial entre reintentos de enganche: 1, 2, 4, 8, 16 y luego 30 s.
enum AgentReconnectPolicy {
    static let maxDelaySeconds = 30

    static func delaySeconds(attempt: Int) -> Int {
        guard attempt > 1 else { return 1 }
        let exponent = min(attempt - 1, 5)
        return min(maxDelaySeconds, 1 << exponent)
    }
}

/// Resultado de enviar un mensaje a un agente persistente.
enum AgentSendOutcome: Equatable, Sendable {
    /// Llegó al agente: ya se puede vaciar el borrador.
    case sent
    /// No llegó (el motivo queda en `lastError`): el borrador se conserva.
    case failed
    /// El agente está hibernado en un modo que actúa sin preguntar: hay que confirmar la
    /// reanudación antes de enviar.
    case needsResumeConfirmation
}
