//
//  IntegrationAgentTests.swift
//  ArgosTests
//
//  Agentes persistentes contra un servidor real con el `claude` simulado: lanzar, enviar
//  (corto por la orden y largo por stdin), reenganche incremental, líneas enormes, permisos
//  y avisos, agente que muere al arrancar y envío a un agente muerto. Parar, hibernar,
//  reanudar, rotar e inventario están en `IntegrationAgentLifecycleTests`.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Agentes persistentes: conversación")
@MainActor
struct AgentConversation {

    @Test("Argos encuentra el claude simulado (nunca uno real)", .timeLimit(.minutes(1)))
    func locatesFakeClaude() async throws {
        let box = try await RemoteBox.open("agent-locate")
        defer { IntegrationCleanup.later { await box.close() } }
        #expect(try await box.service.locateClaude() == box.fakeClaude)
    }

    @Test("Lanzar, enviar, desengancharse y reengancharse sin duplicar ni perder nada", .timeLimit(.minutes(2)))
    func launchSendAndReattach() async throws {
        let box = try await RemoteBox.open("agent-basic")
        let agent = try await box.launchAgent()
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }

        #expect(try await box.isAlive(agent))
        let listed = try await PersistentAgentSession.list(service: box.service)
        #expect(listed.first { $0.id == agent.id }?.isAlive == true)
        // Un segundo lanzamiento con el agente vivo no crea otro claude.
        try await box.start(id: agent.id, meta: agent.meta, resume: false, hibernation: noHibernation)
        #expect(try await box.processes(matching: agent.id).filter { $0.contains("stream-json") }.count == 1)

        let session = try await box.session(for: agent)
        session.attach()
        #expect(try await eventually(seconds: 15) { session.link.isLive })
        #expect(await session.send("hola") == .sent)
        #expect(try await eventually(seconds: 15) { session.assistantTexts.contains { $0.hasSuffix(": hola") } })
        let seen = session.receivedBytes
        #expect(seen > 0)

        // Desenganchado, el agente sigue trabajando.
        session.detach()
        #expect(await session.send("segundo") == .sent)
        #expect(try await eventually(seconds: 15) { try await box.agentLog(agent).contains("segundo") })
        session.attach()
        #expect(try await eventually(seconds: 15) { session.assistantTexts.contains { $0.hasSuffix(": segundo") } })
        #expect(session.userTexts == ["hola", "segundo"], "Sin duplicados: \(session.userTexts)")
        #expect(session.receivedBytes > seen)

        // Otra app (o recargar) reconstruye la conversación entera desde el principio.
        let other = try await box.session(for: agent)
        other.attach()
        #expect(try await eventually(seconds: 15) { other.assistantTexts.count == 2 })
        #expect(other.receivedBytes == session.receivedBytes)
        other.detach()
        session.detach()

        // El tail de cada enganche muere al cerrarse su canal (sin huérfanos).
        let tails = try await eventually(seconds: 10) {
            try await box.processes(matching: "tail -c").filter { $0.contains(agent.id) }.isEmpty
        }
        #expect(tails, "Quedaron tails colgados")
    }

    @Test("Un mensaje de más de 96 KiB va por stdin y llega entero", .timeLimit(.minutes(2)))
    func longMessageViaStdin() async throws {
        let box = try await RemoteBox.open("agent-long")
        let agent = try await box.launchAgent()
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let session = try await box.session(for: agent)

        let text = "largo " + String(repeating: "ñandú 0123456789 ", count: 6_000) + "fin"
        let line = AgentProtocol.encodeUserMessage(text: text)
        #expect(line.utf8.count > PersistentAgentScript.maxInlineCommandBytes)
        #expect(PersistentAgentScript.needsStdin(line: line))
        #expect(await session.send(text) == .sent, "Error: \(session.lastError ?? "-")")

        let expected = "recv \(line.utf8.count + 1)"
        let received = try await eventually(seconds: 20) { try await box.fakeCalls(agent).contains(expected) }
        let calls = try await box.fakeCalls(agent)
        #expect(received, "El simulado no recibió la línea entera (\(expected)): \(calls) \(session.lastError ?? "-")")
        let leftovers = try await box.sh("ls -a \(agent.directory) | grep '^\\.send' ; true")
        #expect(leftovers.isEmpty, "Temporales de envío sin borrar: \(leftovers)")
        // Y otro corto después: la FIFO sigue sana.
        #expect(await session.send("después") == .sent)
        #expect(try await eventually(seconds: 15) { try await box.agentLog(agent).contains(": después") })
    }

    @Test("Una línea enorme del agente se lee y los avisos ven un permiso de un Write gigante",
          .timeLimit(.minutes(2)))
    func hugeLinesAndPermissionNotice() async throws {
        let box = try await RemoteBox.open("agent-huge")
        let agent = try await box.launchAgent(modes: ["huge-line 300000", "permission"])
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let session = try await box.session(for: agent)
        session.attach()
        #expect(try await eventually(seconds: 20) { session.receivedBytes > 300_000 })
        #expect(session.assistantTexts.count == 1)

        #expect(await session.send("haz esto con PERMISO") == .sent)
        #expect(try await eventually(seconds: 20) { session.state.pendingPermission?.toolName == "Write" })
        session.detach()

        let snapshots = PersistentAgentScript.parseSnapshots(try await box.sh(PersistentAgentScript.snapshots()))
        let mine = try #require(snapshots.first { $0.id == agent.id })
        #expect(AgentAttention.evaluate(logTail: mine.tail) == .needsPermission(tool: "Write"))
        let inventory = try await box.service.serverAgentInventory()
        #expect(inventory.agents.first { $0.sessionID == agent.id }?.hasPendingPermission == true)
    }

    @Test("Si claude muere al arrancar, el lanzamiento lo dice con el final de err.log", .timeLimit(.minutes(1)))
    func agentThatDiesAtLaunch() async throws {
        let box = try await RemoteBox.open("agent-die")
        defer { IntegrationCleanup.later { await box.close() } }
        do {
            let agent = try await box.launchAgent(modes: ["die"])
            await box.removeAgents([agent])
            Issue.record("El lanzamiento debía fallar")
        } catch PersistentAgentError.launchFailed(let detail) {
            #expect(detail.contains("fallo al arrancar"), "Detalle: \(detail)")
        }
    }

    @Test("Enviar a un agente muerto falla enseguida (corto y largo) con su err.log", .timeLimit(.minutes(2)))
    func sendToDeadAgentDoesNotHang() async throws {
        let box = try await RemoteBox.open("agent-dead")
        let agent = try await box.launchAgent()
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        try await box.sh("printf 'último error del agente\\n' >> \(agent.directory)/err.log")
        let session = try await box.session(for: agent)
        try await box.sh(PersistentAgentScript.stop(id: agent.id, delete: false, graceSeconds: 2))
        #expect(try await box.isAlive(agent) == false)

        let start = ContinuousClock.now
        #expect(await session.send("¿sigues?") == .failed)
        #expect(session.isAlive == false)
        #expect(session.lastError?.contains("último error del agente") == true, "\(session.lastError ?? "-")")
        #expect(await session.send(String(repeating: "x", count: 40_000)) == .failed)
        #expect(ContinuousClock.now - start < .seconds(20))
    }
}

}
