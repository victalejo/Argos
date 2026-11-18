//
//  IntegrationSSHDTests.swift
//  ArgosTests
//
//  Pruebas de integración de `SSHService` contra un sshd REAL y temporal con pocos canales
//  (`MaxSessions`), para cazar los fallos de agotamiento de canales que los mocks no ven.
//  Solo con el entorno de `IntegrationSSHD` (ver ese archivo); si no, se saltan.
//

import Foundation
import Testing
@testable import Argos

@Suite("Integración SSH (sshd real)", .enabled(if: IntegrationSSHD.enabled), .serialized)
struct IntegrationSSHDTests {

    init() { IntegrationSSHD.forgetHostKey() }

    @Test("Una ráfaga de comandos cortos muy por encima de MaxSessions termina sin errores",
          .timeLimit(.minutes(2)))
    func commandBurst() async throws {
        let service = IntegrationSSHD.service()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }

        let count = max(40, IntegrationSSHD.maxSessions * 10)
        let outputs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<count {
                group.addTask {
                    // El `sleep` fuerza que los canales coincidan en el servidor.
                    let out = try await service.runAgentScript("sleep 0.05; echo burst-\(index)")
                    return (index, out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        #expect(outputs.count == count)
        #expect(outputs.allSatisfy { $0.value == "burst-\($0.key)" })
    }

    @Test("Subidas SFTP en paralelo no dejan canales abiertos", .timeLimit(.minutes(2)))
    func parallelUploadsLeaveNoChannels() async throws {
        let service = IntegrationSSHD.service()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-it-up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        let uploads = max(12, IntegrationSSHD.maxSessions * 3)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<uploads {
                group.addTask {
                    _ = try await service.upload(data: payload, toRemotePath: directory.appendingPathComponent("f\(index).bin").path)
                }
            }
            try await group.waitForAll()
        }
        for index in 0..<uploads {
            let size = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("f\(index).bin").path
            )[.size] as? Int
            #expect(size == payload.count)
        }

        // Nada de canales SFTP huérfanos (como mucho el compartido), con margen para cerrar.
        var open = IntegrationSSHD.openSFTPChannelCount()
        for _ in 0..<20 where open > 1 {
            try await Task.sleep(for: .milliseconds(250))
            open = IntegrationSSHD.openSFTPChannelCount()
        }
        #expect(open <= 1, "Quedaron \(open) canales SFTP abiertos tras las subidas")

        // Y se pueden volver a ocupar los canales hasta el límite (menos uno para el SFTP).
        let simultaneous = max(1, IntegrationSSHD.maxSessions - 1)
        let outs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<simultaneous {
                group.addTask { try await service.runAgentScript("sleep 1; echo hold-\(index)") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outs.count == simultaneous)
    }

    @Test("Si el servidor muere y vuelve, la siguiente operación reconecta",
          .enabled(if: IntegrationSSHD.canRestart), .timeLimit(.minutes(2)))
    func reconnectsAfterServerRestart() async throws {
        let service = IntegrationSSHD.service()
        defer { Task { await service.disconnect(); IntegrationSSHD.forgetHostKey() } }

        let before = try await service.runAgentScript("echo antes")
        #expect(before.contains("antes"))

        try IntegrationSSHD.killServer()
        var failedWhileDown = false
        do { _ = try await service.runAgentScript("echo caido") } catch { failedWhileDown = true }
        #expect(failedWhileDown, "Con el servidor muerto la operación debería fallar")

        try IntegrationSSHD.restartServer()
        let after = try await service.runAgentScript("echo despues")
        #expect(after.contains("despues"))
    }

    @Test("El túnel de puertos sirve peticiones en paralelo contra este sshd", .timeLimit(.minutes(2)))
    func portForwardAgainstTemporarySshd() async throws {
        let service = IntegrationSSHD.service()
        let remotePort = Int.random(in: 20_000...40_000)
        let marker = "argos-it-\(UUID().uuidString)"
        // Sin `nohup`: en macOS falla sin terminal («can't detach from console»).
        let setup = """
        d=$(mktemp -d /tmp/argos-it.XXXXXX) && cd "$d" && printf '%s' '\(marker)' > index.html && \
        (python3 -m http.server \(remotePort) --bind 127.0.0.1 </dev/null >/dev/null 2>&1 & echo "$! $d")
        """
        let started = try await service.runAgentScript(setup)
        let parts = started.split(whereSeparator: \.isWhitespace).map(String.init)
        try #require(parts.count == 2)
        defer {
            Task {
                _ = try? await service.runAgentScript("kill \(parts[0]); rm -rf '\(parts[1])'")
                await service.disconnect()
                IntegrationSSHD.forgetHostKey()
            }
        }

        let forward = try await service.startPortForward(
            remotePort: remotePort, targetHost: "127.0.0.1", preferredLocalPort: 0
        )
        let url = try #require(URL(string: "http://127.0.0.1:\(forward.localPort)/index.html"))
        let session = URLSession(configuration: .ephemeral)

        // El servidor tarda un instante en escuchar: se reintenta la primera petición.
        var first: String?
        for _ in 0..<20 where first == nil {
            if let (data, _) = try? await session.data(from: url) { first = String(decoding: data, as: UTF8.self) }
            else { try await Task.sleep(for: .milliseconds(250)) }
        }
        #expect(first == marker)

        let bodies = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let (data, _) = try await session.data(from: url)
                    return String(decoding: data, as: UTF8.self)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(bodies.count == 8)
        #expect(bodies.allSatisfy { $0 == marker })
        await service.stopPortForward(id: forward.id)
        #expect(await service.activePortForwards().isEmpty)
    }
}
