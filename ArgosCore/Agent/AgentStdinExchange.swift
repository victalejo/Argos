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

    /// Plazo por defecto para recibir la respuesta.
    static let defaultTimeout: Duration = .seconds(45)

    /// Ejecuta `command` por un canal exec, le escribe `input` por stdin y devuelve la
    /// primera línea de stdout que `accept` reconozca (las anteriores, p. ej. ruido que
    /// imprime el perfil del shell, se ignoran). stdin se cierra en cuanto llega. Si no
    /// llega en `timeout`, se cancela el canal y se lanza `AgentExchangeTimeout`.
    static func firstLine(
        service: any SSHServicing,
        command: String,
        input: [UInt8],
        timeout: Duration = defaultTimeout,
        accept: @escaping @Sendable (String) -> Bool = { !$0.isEmpty }
    ) async throws -> String {
        let (stdin, writer) = AsyncStream<[UInt8]>.makeStream()
        writer.yield(input)
        let (outputStream, output) = AsyncStream<[UInt8]>.makeStream()
        let run = Task { try await service.runAgentExec(command: command, stdin: stdin, output: output) }
        let timer = Task<Bool, Never> {
            do { try await Task.sleep(for: timeout) } catch { return false }
            writer.finish()
            run.cancel()
            output.finish()
            return true
        }
        var pending = ""
        var accepted: String?
        reading: for await chunk in outputStream {
            pending += String(decoding: chunk, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline]).trimmingCharacters(in: .whitespaces)
                pending = String(pending[pending.index(after: newline)...])
                if accept(line) { accepted = line; break reading }
            }
        }
        writer.finish()
        timer.cancel()
        let timedOut = await timer.value
        var channelError: Error?
        do {
            try await run.value
        } catch {
            channelError = error
        }
        if let accepted { return accepted }
        let leftover = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty, accept(leftover) { return leftover }
        if timedOut {
            Log.agent.error("El servidor no respondió a tiempo.")
            throw AgentExchangeTimeout()
        }
        if let channelError {
            Log.agent.error("Sin respuesta del servidor: \(channelError.localizedDescription, privacy: .private)")
            throw channelError
        }
        throw AgentExecError(message: String(localized: "El servidor no respondió."))
    }
}

/// El servidor no contestó a tiempo (conexión colgada o comando bloqueado).
struct AgentExchangeTimeout: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "El servidor no respondió a tiempo. Comprueba la conexión y vuelve a intentarlo.")
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
