//
//  ConnectionMonitorTests.swift
//  ArgosTests
//
//  Vigilantes y turnos con plazo (sin red): cuándo se da por muerta una conexión, qué
//  hace un comando que vence con el canal abierto, el plazo en el servidor y que lo que
//  esperaba turno no reabra la conexión tras desconectar.
//

import Foundation
import Testing
@preconcurrency import Citadel
import NIOCore
@testable import Argos

@Suite("Vigilancia de conexiones")
struct LinkLivenessTests {

    @Test("Un canal rechazado prueba que el servidor está vivo")
    func rejectionIsAlive() {
        let failing = LinkLiveness(consecutiveFailures: 2)
        #expect(failing.recording(.rejected, threshold: 3) == LinkLiveness())
        #expect(failing.recording(.alive, threshold: 3) == LinkLiveness())
    }

    @Test("Hacen falta varios sondeos sin respuesta seguidos para cerrar")
    func needsConsecutiveFailures() {
        var liveness = LinkLiveness()
        for _ in 0..<2 { liveness = liveness.recording(.unresponsive, threshold: 3) }
        #expect(!liveness.isDead(threshold: 3))
        #expect(liveness.recording(.unresponsive, threshold: 3).isDead(threshold: 3))
        // Uno bueno entremedias reinicia la cuenta.
        #expect(liveness.recording(.alive, threshold: 3).recording(.unresponsive, threshold: 3).consecutiveFailures == 1)
    }

    @Test("Una conexión ya cerrada está muerta sin esperar")
    func brokenIsDead() {
        #expect(LinkLiveness().recording(.broken, threshold: 3).isDead(threshold: 3))
    }

    @Test("Clasifica los errores de un sondeo")
    func classifiesProbeErrors() {
        #expect(ProbeOutcome.from(error: CitadelError.channelCreationFailed) == .unresponsive)
        #expect(ProbeOutcome.from(error: SSHConnectionError.commandTimedOut(.seconds(20))) == .unresponsive)
        #expect(ProbeOutcome.from(error: ChannelError.ioOnClosedChannel) == .broken)
        #expect(ProbeOutcome.from(error: ChannelError.eof) == .broken)
        #expect(ProbeOutcome.from(error: SSHConnectionError.notConnected) == .broken)
    }

    @Test("La actividad reciente cuenta dentro de la ventana")
    func activityWindow() {
        let activity = LinkActivity()
        #expect(!activity.isRecent(within: .seconds(30)))
        let now = ContinuousClock.now
        activity.touch(at: now)
        #expect(activity.isRecent(within: .seconds(30), now: now + .seconds(10)))
        #expect(!activity.isRecent(within: .seconds(30), now: now + .seconds(31)))
        activity.reset()
        #expect(activity.last == nil)
    }

    @Test("La política por defecto es prudente")
    func defaultPolicy() {
        let policy = ConnectionMonitorPolicy.standard
        #expect(policy.linkFailuresToClose >= 2)
        #expect(policy.sharedFailuresToDiscard >= 2)
        #expect(ConnectionMonitorPolicy(linkFailuresToClose: 0).linkFailuresToClose == 1)
    }
}

@Suite("Turnos con plazo de SSHService")
struct HeldTurnTests {

    private struct Late: Error {}

    private func makeService() -> SSHService {
        SSHService(configuration: .init(server: Server(name: "prueba", host: "127.0.0.1", username: "nadie")))
    }

    @Test("Un plazo vencido no libera el cupo mientras el canal sigue abierto", .timeLimit(.minutes(1)))
    func expiredKeepsTurnUntilChannelEnds() async throws {
        let service = makeService()
        let gate = service.channelGate
        let release = Gate()
        let started = ContinuousClock.now
        await #expect(throws: SSHConnectionError.self) {
            _ = try await service.runInChannelTurn(timeout: .custom(.milliseconds(100))) {
                await release.wait()   // el «comando remoto» sigue corriendo
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        // Quien llama ya se fue, pero el turno sigue ocupado.
        #expect(await gate.activeCount == 1)
        #expect(await service.abandonedCommands.count == 1)

        await release.open()
        while await gate.activeCount > 0 { await Task.yield() }
        #expect(await service.abandonedCommands.isEmpty)
    }

    @Test("Dentro del plazo devuelve el valor y libera el turno")
    func withinDeadline() async throws {
        let service = makeService()
        let value = try await service.runInChannelTurn(timeout: .standard) { 7 }
        #expect(value == 7)
        while await service.channelGate.activeCount > 0 { await Task.yield() }
    }

    @Test("Canal rechazado: reintenta con el tope bajado", .timeLimit(.minutes(1)))
    func rejectionRetries() async throws {
        let service = makeService()
        let calls = Counter()
        let value = try await service.runInChannelTurn(timeout: .standard, isRejection: { $0 is Late }) {
            if await calls.increment() < 2 { throw Late() }
            return "ok"
        }
        #expect(value == "ok")
        #expect(await service.channelGate.currentLimit < ChannelGate.sharedConnectionLimit)
    }

    @Test("Lo que esperaba turno al desconectar no reabre la conexión")
    func queuedAfterDisconnect() async throws {
        let service = makeService()
        let gate = service.channelGate
        for _ in 0..<ChannelGate.sharedConnectionLimit { try await gate.acquire() }
        let ran = Counter()
        let queued = Task {
            try await service.runInChannelTurn(timeout: .standard) { _ = await ran.increment() }
        }
        while await gate.waitingCount == 0 { await Task.yield() }
        await service.disconnect()
        await gate.release()
        await #expect(throws: SSHConnectionError.self) { try await queued.value }
        #expect(await ran.value == 0)
        for _ in 1..<ChannelGate.sharedConnectionLimit { await gate.release() }
    }
}

@Suite("Plazo en el servidor")
struct RemoteTimeoutTests {

    @Test("Envuelve con timeout si existe y si no, corre tal cual")
    func wrapsCommand() {
        let wrapped = RemoteTimeout.wrap("tmux list-sessions -F '#{session_name}'", seconds: 60)
        #expect(wrapped.contains("command -v timeout"))
        #expect(wrapped.contains("timeout -k 5 60 sh -c"))
        #expect(wrapped.contains("else sh -c"))
    }

    @Test("El comando envuelto da la misma salida y código (en este Mac, con o sin timeout)")
    func runsLocally() throws {
        let wrapped = RemoteTimeout.wrap("printf '%s' \"a'b\"; exit 3", seconds: 5)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", wrapped]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == "a'b")
        #expect(process.terminationStatus == 3)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}

/// Puerta que se abre una vez (simula un comando remoto que tarda).
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
