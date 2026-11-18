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
//   - Cada comando tiene plazo (`CommandTimeout`): quien espera uno colgado recibe
//     `SSHConnectionError.commandTimedOut`; su canal sigue ocupando turno hasta cerrarse
//     de verdad, y con varios así la conexión se recicla (ver `runInChannelTurn`).
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
        try await runInChannelTurn(timeout: timeout) { [self] in
            try await captureInTurn(command, requireExisting: false)
        }
    }

    /// Ejecuta un comando corto best-effort SOLO si la conexión compartida ya está viva (no
    /// reconecta). Devuelve si salió con código 0.
    @discardableResult
    func captureIfConnected(_ command: String) async -> Bool {
        guard let client, client.isConnected else { return false }
        do {
            let output = try await runInChannelTurn(timeout: .standard) { [self] in
                try await captureInTurn(command, requireExisting: true)
            }
            return output.exitCode == 0
        } catch {
            Log.ssh.notice("Comando best-effort falló: \(error.userMessage, privacy: .public)")
            return false
        }
    }

    /// Como `captureIfConnected`, pero SIN esperar turno y con un plazo corto: para la
    /// limpieza al desconectar, que no debe quedarse detrás de un comando largo en curso.
    @discardableResult
    func captureNowIfConnected(_ command: String, within limit: Duration = .seconds(5)) async -> Bool {
        guard let client, client.isConnected else { return false }
        let succeeded = await Deadline.succeeds(within: limit) { [weak self] in
            await self?.captureOnExistingShared(command) ?? false
        }
        if !succeeded { Log.ssh.notice("Limpieza best-effort sin respuesta a tiempo: se omite") }
        return succeeded
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
    /// nada, así que repetir es seguro. Cancelable mientras espera turno. Sin plazo: lo usan
    /// las transferencias SFTP, que duran lo que duren.
    ///
    /// `isRejection` solo se sustituye en los tests (`NIOSSHError` no se puede construir).
    func withShortChannel<T>(
        isRejection: (Error) -> Bool = ChannelRetry.isChannelRejection,
        _ body: () async throws -> T
    ) async throws -> T {
        let priority = ConnectionPriority.current
        let epoch = connectionEpoch
        var attempt = 1
        while true {
            try await acquireTurn(priority, epoch: epoch)
            do {
                try Task.checkCancellation()
                let value = try await body()
                sharedActivity.touch()
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

    /// Turno de canal para una operación con plazo. Si el plazo vence, quien llama recibe
    /// `SSHConnectionError.commandTimedOut` enseguida, pero el turno NO se libera hasta que
    /// el canal se cierra de verdad (cancelar solo dejaría de leer: el canal seguiría
    /// abierto en el servidor y se pasaría de `MaxSessions`). Lo suelta la propia tarea.
    /// Pasados `abandonedChannelLimit` canales así, se recicla la conexión.
    func runInChannelTurn<T: Sendable>(
        timeout: CommandTimeout,
        isRejection: @escaping @Sendable (Error) -> Bool = ChannelRetry.isChannelRejection,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let priority = ConnectionPriority.current
        let epoch = connectionEpoch
        var attempt = 1
        while true {
            try await acquireTurn(priority, epoch: epoch)
            do {
                return try await runHoldingTurn(
                    priority: priority, limit: timeout.duration, isRejection: isRejection, operation
                )
            } catch where isRejection(error) && attempt < ChannelRetry.maxAttempts {
                Log.ssh.notice("Canal rechazado por \(self.configuration.host, privacy: .public) (intento \(attempt)); se reintenta.")
                try await Task.sleep(for: ChannelRetry.delay(forAttempt: attempt))
                attempt += 1
            }
        }
    }

    // MARK: - Internos

    /// Espera turno; si entretanto se desconectó, lo devuelve y no sigue: abrir aquí una
    /// conexión nueva la dejaría sin dueño.
    private func acquireTurn(_ priority: ConnectionPriority, epoch: Int) async throws {
        try await channelGate.acquire(priority)
        guard epoch == connectionEpoch else {
            await channelGate.release(priority)
            throw SSHConnectionError.notConnected
        }
    }

    private func runHoldingTurn<T: Sendable>(
        priority: ConnectionPriority,
        limit: Duration,
        isRejection: @escaping @Sendable (Error) -> Bool,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        heldCommands.insert(id)
        let (results, continuation) = AsyncStream<Result<T, Error>>.makeStream()
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            await self?.abandonHeldCommand(id, after: limit)
            continuation.yield(.failure(SSHConnectionError.commandTimedOut(limit)))
        }
        // NO es hija de quien llama: si este se cancela o vence el plazo, el canal sigue
        // ocupando su turno hasta que termine de verdad.
        Task {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            timer.cancel()
            let rejected: Bool
            if case .failure(let error) = result { rejected = isRejection(error) } else { rejected = false }
            await self.finishHeldCommand(id, priority: priority, rejected: rejected)
            continuation.yield(result)
            continuation.finish()
        }
        for await result in results { return try result.get() }
        throw CancellationError()
    }

    private func finishHeldCommand(_ id: UUID, priority: ConnectionPriority, rejected: Bool) async {
        heldCommands.remove(id)
        if abandonedCommands.remove(id) != nil {
            Log.ssh.debug("Se cerró un canal cuyo comando había vencido (quedan \(self.abandonedCommands.count))")
        }
        if rejected {
            let lowered = await channelGate.lowerLimitAfterRejection()
            Log.ssh.notice("Canal rechazado por \(self.configuration.host, privacy: .public); tope bajado a \(lowered).")
        }
        await channelGate.release(priority)
    }

    /// El comando venció y su canal sigue abierto: cuenta como abandonado. Con demasiados,
    /// la conexión compartida se recicla (cerrarla cierra sus canales y libera los turnos).
    private func abandonHeldCommand(_ id: UUID, after limit: Duration) {
        guard heldCommands.contains(id) else { return }
        abandonedCommands.insert(id)
        Log.ssh.notice("Un comando en \(self.configuration.host, privacy: .public) no terminó en \(limit.components.seconds) s; su canal sigue ocupando turno (\(self.abandonedCommands.count) así)")
        guard abandonedCommands.count >= monitorPolicy.abandonedChannelLimit, client != nil else { return }
        Log.ssh.error("Demasiados canales colgados en \(self.configuration.host, privacy: .public): se recicla la conexión compartida")
        replaceSharedClient(with: nil)
    }

    private func captureInTurn(_ command: String, requireExisting: Bool) async throws -> CommandOutput {
        let client = try await sharedClientInTurn(requireExisting: requireExisting)
        let output = try await captureOnce(client, command: command)
        sharedActivity.touch()
        return output
    }

    private func captureOnExistingShared(_ command: String) async -> Bool {
        guard let client, client.isConnected else { return false }
        return (try? await captureOnce(client, command: command))?.exitCode == 0
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
