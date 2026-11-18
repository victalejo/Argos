//
//  IntegrationConnectionMonitorTests.swift
//  ArgosTests
//
//  Vigilantes, plazos y túneles de `SSHService` contra el sshd REAL y temporal de
//  `IntegrationSSHD` (se saltan sin él). Pensados para correr con `MaxSessions` 1, 4 y 6:
//  con 1, todo sondeo extra se rechaza y la conexión NO debe darse por muerta.
//

import Foundation
import Testing
@testable import Argos

@Suite("Integración: vigilancia de conexiones (sshd real)", .enabled(if: IntegrationSSHD.enabled), .serialized)
struct IntegrationConnectionMonitorTests {

    init() { IntegrationSSHD.forgetHostKey() }

    /// Vigilantes muy rápidos para no esperar 30 s.
    private static let fastPolicy = ConnectionMonitorPolicy(
        heartbeatInterval: .milliseconds(300), heartbeatTimeout: .seconds(3), sharedFailuresToDiscard: 2,
        linkInterval: .milliseconds(300), linkTimeout: .seconds(3), linkFailuresToClose: 3,
        retryInterval: .milliseconds(300)
    )

    private func fastService() async -> SSHService {
        let service = IntegrationSSHD.service()
        await service.setMonitorPolicy(Self.fastPolicy)
        return service
    }

    @Test("Un exec dedicado sobrevive a varios ciclos del vigilante (también con MaxSessions 1)",
          .timeLimit(.minutes(1)))
    func dedicatedExecSurvivesMonitor() async throws {
        let service = await fastService()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }
        let (stdin, input) = AsyncStream<[UInt8]>.makeStream()
        let (output, sink) = AsyncStream<[UInt8]>.makeStream()
        let exec = Task { try await service.runAgentExec(command: "cat", stdin: stdin, output: sink) }

        // Varios sondeos (rechazados con MaxSessions 1, aceptados con más canales).
        try await waitUntil(seconds: 20) { await service.linkProbeCount >= 4 }
        #expect(await service.dedicatedLinkIDs.count == 1)

        input.yield(Array("hola\n".utf8))
        var echoed = ""
        for await chunk in output {
            echoed += String(decoding: chunk, as: UTF8.self)
            if echoed.contains("hola") { break }
        }
        #expect(echoed.contains("hola"))
        input.finish()
        try await exec.value
    }

    @Test("El latido no tumba la compartida mientras corre un comando largo", .timeLimit(.minutes(1)))
    func heartbeatSparesBusySharedConnection() async throws {
        let service = await fastService()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }
        let output = try await service.run("sleep 3; echo fin", timeout: .custom(.seconds(30)))
        #expect(output.stdout.contains("fin"))
        #expect(await service.sharedProbeCount >= 2)
        let again = try await service.run("echo sigue")
        #expect(again.stdout.contains("sigue"))
    }

    @Test("Un comando vencido sigue ocupando su turno hasta que el canal se cierra", .timeLimit(.minutes(1)))
    func expiredCommandHoldsTurn() async throws {
        let service = await fastService()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }
        _ = try await service.run("true")
        await #expect(throws: SSHConnectionError.self) {
            _ = try await service.run("sleep 4", timeout: .custom(.seconds(1)))
        }
        #expect(await service.channelGate.activeCount == 1)
        try await waitUntil(seconds: 15) { await service.channelGate.activeCount == 0 }
        let after = try await service.run("echo libre")
        #expect(after.stdout.contains("libre"))
    }

    @Test("Con plazo en el servidor, un sondeo colgado no deja el canal abierto", .timeLimit(.minutes(1)))
    func remoteTimeoutKillsHungPoll() async throws {
        let service = IntegrationSSHD.service()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }
        let hasTimeout = try await service.run("command -v timeout >/dev/null 2>&1 && echo si").stdout.contains("si")
        let started = ContinuousClock.now
        let result = try await service.run(RemoteTimeout.wrap("sleep 8", seconds: 1), timeout: .custom(.seconds(20)))
        if hasTimeout {
            #expect(result.exitCode == RemoteTimeout.expiredExitCode)
            #expect(ContinuousClock.now - started < .seconds(7))
        } else {
            // Sin `timeout` en el servidor el comando corre tal cual (respaldo).
            #expect(result.exitCode == 0)
        }
    }

    @Test("withDedicatedClient termina con connectionLost cuando el vigilante la cierra", .timeLimit(.minutes(1)))
    func lostDedicatedReportsConnectionLost() async throws {
        let service = IntegrationSSHD.service()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }
        let (stdin, input) = AsyncStream<[UInt8]>.makeStream()
        let (_, sink) = AsyncStream<[UInt8]>.makeStream()
        let exec = Task { try await service.runAgentExec(command: "cat", stdin: stdin, output: sink) }
        try await waitUntil(seconds: 15) { await !service.dedicatedLinkIDs.isEmpty }
        let id = try #require(await service.dedicatedLinkIDs.first)
        await service.simulateLinkLoss(id)
        await #expect(throws: SSHConnectionError.connectionLost) { try await exec.value }
        input.finish()
    }

    @Test("Un túnel reabierto tras perder su conexión conserva su vigilante", .timeLimit(.minutes(1)))
    func reopenedTunnelKeepsMonitor() async throws {
        let service = IntegrationSSHD.service()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }
        // El propio sshd escucha siempre: sirve de destino del túnel.
        let forward = try await service.startPortForward(
            remotePort: IntegrationSSHD.port, targetHost: "127.0.0.1", preferredLocalPort: 0
        )
        #expect(await service.hasLinkMonitor(forward.id))

        await service.simulateLinkLoss(forward.id)
        try await waitUntil(seconds: 20) {
            let connected = await service.isLinkConnected(forward.id)
            let watched = await service.hasLinkMonitor(forward.id)
            return connected && watched
        }
        let listed = await service.activePortForwards()
        #expect(listed.contains { $0.id == forward.id && $0.localPort == forward.localPort })
        await service.stopPortForward(id: forward.id)
        #expect(await !service.hasLinkMonitor(forward.id))
    }

    // MARK: - Apoyo

    private struct TimedOut: Error {}

    private func waitUntil(seconds: Int, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
