//
//  ShortChannelTests.swift
//  ArgosTests
//
//  El camino de un comando corto en `SSHService` (sin red): rechazo del canal por el
//  servidor (baja el tope y reintenta), cancelación mientras espera turno (no ejecuta) y
//  plazo por comando (`Deadline.value`).
//

import Foundation
import Testing
@testable import Argos

@Suite("Canales cortos de SSHService")
struct ShortChannelTests {

    private struct Rejected: Error {}
    private struct Boom: Error {}

    private func makeService() -> SSHService {
        SSHService(configuration: .init(server: Server(name: "prueba", host: "127.0.0.1", username: "nadie")))
    }

    @Test("Canal rechazado: baja el tope de la conexión y reintenta hasta que entra")
    func rejectionLowersLimitAndRetries() async throws {
        let service = makeService()
        let calls = Counter()
        let value = try await service.withShortChannel(isRejection: { $0 is Rejected }) {
            if await calls.increment() < 3 { throw Rejected() }
            return "ok"
        }
        #expect(value == "ok")
        #expect(await calls.value == 3)
        #expect(await service.channelGate.currentLimit < ChannelGate.sharedConnectionLimit)
        #expect(await service.channelGate.activeCount == 0)
    }

    @Test("Canal rechazado siempre: se rinde tras los reintentos y libera el turno")
    func rejectionGivesUp() async {
        let service = makeService()
        let calls = Counter()
        await #expect(throws: Rejected.self) {
            try await service.withShortChannel(isRejection: { $0 is Rejected }) {
                _ = await calls.increment()
                throw Rejected()
            }
        }
        #expect(await calls.value == ChannelRetry.maxAttempts)
        #expect(await service.channelGate.activeCount == 0)
    }

    @Test("Otros errores no se reintentan")
    func otherErrorsPropagate() async {
        let service = makeService()
        let calls = Counter()
        await #expect(throws: Boom.self) {
            try await service.withShortChannel {
                _ = await calls.increment()
                throw Boom()
            }
        }
        #expect(await calls.value == 1)
        #expect(await service.channelGate.activeCount == 0)
    }

    @Test("Cancelado mientras espera turno: sale de la cola y el comando no corre")
    func cancelledWhileQueued() async throws {
        let service = makeService()
        let gate = service.channelGate
        for _ in 0..<ChannelGate.sharedConnectionLimit { try await gate.acquire() }
        let ran = Counter()
        let queued = Task {
            try await service.withShortChannel { _ = await ran.increment() }
        }
        while await gate.waitingCount == 0 { await Task.yield() }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await ran.value == 0)
        #expect(await gate.waitingCount == 0)
        for _ in 0..<ChannelGate.sharedConnectionLimit { await gate.release() }
        #expect(await gate.activeCount == 0)
    }

    @Test("Los sondeos de fondo usan el turno de fondo")
    func backgroundUsesBackgroundLane() async throws {
        let service = makeService()
        let lane = try await ConnectionPriority.background {
            try await service.withShortChannel { await service.channelGate.activeCount(.background) }
        }
        #expect(lane == 1)
    }

    // MARK: - Plazo por comando

    private struct Late: Error {}

    @Test("Plazo vencido: lanza el error tipado sin esperar a la operación colgada")
    func deadlineExpires() async {
        let started = ContinuousClock.now
        await #expect(throws: Late.self) {
            try await Deadline.value(within: .milliseconds(50), timeoutError: { Late() }) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Dentro del plazo devuelve el valor o el error de la operación")
    func deadlineMet() async throws {
        let value = try await Deadline.value(within: .seconds(5), timeoutError: { Late() }) { 42 }
        #expect(value == 42)
        await #expect(throws: Boom.self) {
            try await Deadline.value(within: .seconds(5), timeoutError: { Late() }) { () async throws -> Int in throw Boom() }
        }
    }

    @Test("Los plazos largos son explícitos y mayores que el normal")
    func timeoutClasses() {
        #expect(CommandTimeout.standard.duration < CommandTimeout.long.duration)
        #expect(CommandTimeout.long.duration >= .seconds(600))
        #expect(CommandTimeout.custom(.seconds(3)).duration == .seconds(3))
        let message = SSHConnectionError.commandTimedOut(.seconds(90)).errorDescription ?? ""
        #expect(message.contains("90 s"))
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}
