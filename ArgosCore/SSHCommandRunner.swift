//
//  SSHCommandRunner.swift
//  Argos
//
//  Ejecución de comandos cortos sobre la conexión compartida de `SSHService`:
//
//   - Cada comando abre UN canal y respeta el tope de `ChannelGate` (con la clase de
//     turno de la tarea: usuario o fondo, ver `ConnectionPriority`).
//   - La conexión se resuelve DENTRO del turno: quien esperaba en cola usa la conexión
//     vigente al entrar, no la que había (quizá ya cerrada) cuando pidió turno.
//   - Cada comando tiene plazo (`CommandTimeout`): uno colgado libera su turno y falla
//     con `SSHConnectionError.commandTimedOut` en vez de retenerlo para siempre.
//   - Si el servidor rechaza el canal, el tope baja para esa conexión y se reintenta (el
//     comando nunca llegó a ejecutarse).
//

import Foundation
@preconcurrency import Citadel
import NIOCore     // ByteBuffer, String(buffer:)

/// Salida de un comando remoto. Un código distinto de 0 NO es un error aquí.
typealias CommandOutput = (stdout: String, stderr: String, exitCode: Int)

/// Plazo de un comando remoto.
enum CommandTimeout: Sendable, Equatable {
    /// Consultas y acciones normales (tmux, git status, sondeos…).
    case standard
    /// Operaciones legítimamente largas: instalar paquetes, clonar, `git push`/`pull`,
    /// listar un proyecto entero…
    case long
    case custom(Duration)

    var duration: Duration {
        switch self {
        case .standard: return .seconds(90)
        case .long: return .seconds(15 * 60)
        case .custom(let duration): return duration
        }
    }
}

extension SSHService {

    /// Ejecuta un comando capturando stdout, stderr y el código de salida.
    ///
    /// Un exit-code distinto de cero NO lanza aquí: se devuelve para que la capa
    /// superior decida (p. ej. tmux "no server running" sale con código != 0 pero
    /// debe tratarse como lista vacía).
    ///
    /// `client` se conserva por compatibilidad con los llamadores (`let client = try await
    /// connectedClient(); capture(client, …)`), pero se IGNORA: el comando corre sobre la
    /// conexión compartida vigente al conseguir turno.
    func capture(
        _ client: SSHClient,
        command: String,
        timeout: CommandTimeout = .standard
    ) async throws -> CommandOutput {
        try await run(command, timeout: timeout)
    }

    /// Ejecuta un comando corto en la conexión compartida (conectando si hace falta).
    func run(_ command: String, timeout: CommandTimeout = .standard) async throws -> CommandOutput {
        try await runShared(command, timeout: timeout, requireExisting: false)
    }

    /// Ejecuta un comando corto best-effort SOLO si la conexión compartida ya está viva (no
    /// reconecta: p. ej. al desconectar). Devuelve si salió con código 0.
    @discardableResult
    func captureIfConnected(_ command: String) async -> Bool {
        guard let client, client.isConnected else { return false }
        do {
            return try await runShared(command, timeout: .standard, requireExisting: true).exitCode == 0
        } catch {
            Log.ssh.notice("Comando best-effort falló: \(error.userMessage, privacy: .public)")
            return false
        }
    }

    /// Ejecuta `body` con la conexión compartida vigente, dentro de un turno de canal.
    func withSharedChannel<T>(_ body: (SSHClient) async throws -> T) async throws -> T {
        try await withShortChannel {
            let client = try await sharedClientInTurn(requireExisting: false)
            return try await body(client)
        }
    }

    /// Ejecuta `body` (que abre UN canal corto) respetando el tope de la conexión y
    /// reintentando si el servidor rechaza el canal: el rechazo llega antes de ejecutar
    /// nada, así que repetir es seguro. Cancelable mientras espera turno.
    ///
    /// `isRejection` solo se sustituye en los tests (`NIOSSHError` no se puede construir).
    func withShortChannel<T>(
        isRejection: (Error) -> Bool = ChannelRetry.isChannelRejection,
        _ body: () async throws -> T
    ) async throws -> T {
        let priority = ConnectionPriority.current
        var attempt = 1
        while true {
            try await channelGate.acquire(priority)
            do {
                try Task.checkCancellation()
                let value = try await body()
                await channelGate.release(priority)
                return value
            } catch where isRejection(error) && attempt < ChannelRetry.maxAttempts {
                let lowered = await channelGate.lowerLimitAfterRejection()
                await channelGate.release(priority)
                Log.ssh.notice("Canal rechazado por \(self.configuration.host, privacy: .public) (intento \(attempt)); tope bajado a \(lowered) y se reintenta.")
                try await Task.sleep(for: ChannelRetry.delay(forAttempt: attempt))
                attempt += 1
            } catch {
                await channelGate.release(priority)
                throw error
            }
        }
    }

    // MARK: - Internos

    private func runShared(
        _ command: String,
        timeout: CommandTimeout,
        requireExisting: Bool
    ) async throws -> CommandOutput {
        let limit = timeout.duration
        return try await withShortChannel {
            try await Deadline.value(
                within: limit,
                timeoutError: { SSHConnectionError.commandTimedOut(limit) }
            ) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.captureInTurn(command, requireExisting: requireExisting)
            }
        }
    }

    private func captureInTurn(_ command: String, requireExisting: Bool) async throws -> CommandOutput {
        let client = try await sharedClientInTurn(requireExisting: requireExisting)
        return try await captureOnce(client, command: command)
    }

    /// Conexión compartida vigente (abriéndola si hace falta y se permite).
    private func sharedClientInTurn(requireExisting: Bool) async throws -> SSHClient {
        if requireExisting {
            guard let client, client.isConnected else { throw SSHConnectionError.notConnected }
            return client
        }
        return try await connectedClient()
    }

    /// Un comando sobre `client`, SIN turno ni plazo (lo ponen los llamadores). Lo usan
    /// también los latidos, que tienen su canal reservado fuera del cupo.
    func captureOnce(_ client: SSHClient, command: String) async throws -> CommandOutput {
        // Cancelado mientras esperaba (turno, conexión): el comando no debe llegar a correr.
        try Task.checkCancellation()
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        var exitCode = 0

        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer):
                    stdout.writeImmutableBuffer(buffer)
                case .stderr(let buffer):
                    stderr.writeImmutableBuffer(buffer)
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            // Salida con código != 0: capturamos el código; stdout/stderr ya recogidos.
            exitCode = failure.exitCode
        }

        return (String(buffer: stdout), String(buffer: stderr), exitCode)
    }
}
