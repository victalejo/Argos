//
//  PortForwardingE2ETests.swift
//  ArgosTests
//
//  Prueba REAL del túnel contra un servidor SSH. Desactivada salvo que se pasen las
//  variables (con xcodebuild, prefijadas con TEST_RUNNER_):
//    ARGOS_E2E_SSH_HOST, ARGOS_E2E_SSH_USER, ARGOS_E2E_SSH_KEY (ruta a clave Ed25519
//    sin passphrase). Levanta un `python3 -m http.server` temporal en 127.0.0.1 del
//    servidor, lo pide por el túnel (en paralelo y un archivo grande) y lo limpia.
//

import Foundation
import Testing
@testable import Argos

private enum E2E {
    static let env = ProcessInfo.processInfo.environment
    static var host: String? { env["ARGOS_E2E_SSH_HOST"] }
    static var enabled: Bool { host != nil && env["ARGOS_E2E_SSH_USER"] != nil && env["ARGOS_E2E_SSH_KEY"] != nil }

    static func service() -> SSHService {
        let server = Server(
            name: "e2e", host: host ?? "", username: env["ARGOS_E2E_SSH_USER"] ?? "",
            privateKeyPath: env["ARGOS_E2E_SSH_KEY"] ?? ""
        )
        return SSHService(configuration: .init(server: server))
    }
}

@Suite("Reenvío de puertos E2E", .enabled(if: E2E.enabled), .serialized)
struct PortForwardingE2ETests {

    @Test("El túnel sirve peticiones en paralelo y archivos grandes, y se cierra", .timeLimit(.minutes(2)))
    func tunnel() async throws {
        let service = E2E.service()
        let remotePort = Int.random(in: 20_000...40_000)
        let marker = "argos-e2e-\(UUID().uuidString)"

        // Servidor HTTP temporal: index con marcador + 3 MB aleatorios (contrapresión).
        let setup = """
        d=$(mktemp -d /tmp/argos-e2e.XXXXXX) && cd "$d" && \
        printf '%s' '\(marker)' > index.html && \
        head -c 3145728 /dev/urandom > big.bin && \
        (nohup python3 -m http.server \(remotePort) --bind 127.0.0.1 >/dev/null 2>&1 & echo "$! $d")
        """
        let started = try await service.runAgentScript(setup)
        let parts = started.split(whereSeparator: \.isWhitespace).map(String.init)
        try #require(parts.count == 2)
        let (pid, dir) = (parts[0], parts[1])
        defer {
            Task { _ = try? await service.runAgentScript("kill \(pid); rm -rf '\(dir)'"); await service.disconnect() }
        }

        // Espera a que escuche y que el listado de puertos lo vea.
        var detected = false
        for _ in 0..<20 where !detected {
            try await Task.sleep(for: .milliseconds(250))
            detected = try await service.listeningPorts().contains { $0.port == remotePort }
        }
        #expect(detected)

        let forward = try await service.startPortForward(
            remotePort: remotePort, targetHost: "localhost", preferredLocalPort: remotePort
        )
        let base = try #require(URL(string: "http://127.0.0.1:\(forward.localPort)"))
        let session = URLSession(configuration: .ephemeral)

        // 8 peticiones en paralelo (cada una, su canal direct-tcpip).
        let bodies = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let (data, _) = try await session.data(from: base.appendingPathComponent("index.html"))
                    return String(decoding: data, as: UTF8.self)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(bodies.count == 8)
        let allMatch = bodies.allSatisfy { $0 == marker }
        #expect(allMatch)

        let (big, _) = try await session.data(from: base.appendingPathComponent("big.bin"))
        #expect(big.count == 3_145_728)

        #expect(await service.activePortForwards().map(\.id) == [forward.id])
        await service.stopPortForward(id: forward.id)
        #expect(await service.activePortForwards().isEmpty)

        // Cerrado: el puerto local ya no responde.
        var closed = false
        do {
            var request = URLRequest(url: base.appendingPathComponent("index.html"))
            request.timeoutInterval = 3
            _ = try await session.data(for: request)
        } catch {
            closed = true
        }
        #expect(closed)
    }

    @Test("Claude pide un puerto con argos-ports open y Argos lo ve y lo retira", .timeLimit(.minutes(1)))
    func claudeRequest() async throws {
        let service = E2E.service()
        defer { Task { await service.disconnect() } }
        _ = try await service.listeningPorts()   // instala/actualiza la skill en el servidor
        let port = Int.random(in: 40_001...45_000)
        let out = try await service.runAgentScript("$HOME/.claude/skills/argos-puertos/argos-ports open \(port) 'Prueba E2E de Argos'")
        #expect(out.contains("Claude quiere mostrarte el puerto \(port)»"))
        let pending = try await service.pendingPortForwardRequests()
        #expect(pending.first { $0.port == port }?.note == "Prueba E2E de Argos")
        await service.dismissPortForwardRequest(port: port)
        #expect(try await service.pendingPortForwardRequests().allSatisfy { $0.port != port })
    }

    @Test("Un puerto sin nada escuchando cierra la conexión sin colgarse", .timeLimit(.minutes(1)))
    func closedRemotePort() async throws {
        let service = E2E.service()
        let forward = try await service.startPortForward(remotePort: 1, targetHost: "localhost", preferredLocalPort: 0)
        defer { Task { await service.stopPortForward(id: forward.id); await service.disconnect() } }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(forward.localPort)/")!)
        request.timeoutInterval = 10
        var failed = false
        do { _ = try await URLSession(configuration: .ephemeral).data(for: request) } catch { failed = true }
        #expect(failed)
    }
}
