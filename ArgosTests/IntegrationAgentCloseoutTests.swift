//
//  IntegrationAgentCloseoutTests.swift
//  ArgosTests
//
//  Cierre de flecos contra un servidor real con el `claude` simulado: «Detener» el turno
//  de punta a punta (el turno se cierra y el agente sigue aceptando mensajes), engancharse
//  de cero a un log rotado (que empieza por la marca) sin reengancharse sin fin, y enviar
//  mientras el vigilante quiere hibernar.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Agentes persistentes: cierre de flecos")
@MainActor
struct AgentCloseout {

    @Test("Detener el turno: se cierra con su result, el agente sigue vivo y acepta otro mensaje",
          .timeLimit(.minutes(2)))
    func interruptClosesTurnAndKeepsAgent() async throws {
        let box = try await RemoteBox.open("agent-interrupt")
        let agent = try await box.launchAgent()
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let session = try await box.session(for: agent)
        session.attach()
        defer { session.detach() }
        #expect(try await eventually(seconds: 15) { session.link.isLive })

        // Un turno que no termina solo.
        #expect(await session.send("tarea SIN-FIN") == .sent)
        #expect(try await eventually(seconds: 15) { session.assistantTexts.contains("trabajando sin fin") })
        #expect(session.state.status == .working)

        await session.interrupt()
        #expect(try await eventually(seconds: 15) { !session.isInterrupting && session.state.status != .working },
                "El turno no se cerró: \(session.state.status)")
        #expect(try await box.agentLog(agent).contains("\"control_response\""))
        #expect(try await box.isAlive(agent))

        // Sin turno en curso no se manda otra interrupción (y el simulado solo respondería).
        await session.interrupt()
        #expect(!session.isInterrupting)

        #expect(await session.send("otra") == .sent)
        #expect(try await eventually(seconds: 15) { session.assistantTexts.contains { $0.hasSuffix(": otra") } })
        #expect(try await box.isAlive(agent))
    }

    @Test("Engancharse de cero a un log rotado reconstruye lo conservado sin reengancharse sin fin",
          .timeLimit(.minutes(2)))
    func freshAttachAfterRotation() async throws {
        let box = try await RemoteBox.open("agent-rotate-fresh")
        let agent = try await box.launchAgent()
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let writer = try await box.session(for: agent)
        for word in ["uno", "dos", "tres", "cuatro"] {
            #expect(await writer.send(word) == .sent)
            #expect(try await eventually(seconds: 15) { try await box.agentLog(agent).contains(": \(word)") })
        }
        try await box.sh(PersistentAgentScript.stop(id: agent.id, delete: false, graceSeconds: 2))
        let total = try #require(Int(try await box.sh("wc -c < \(agent.directory)/out.ndjson | tr -d ' '")
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        try await box.sh(PersistentAgentShell.rotateOutputLog(agent.directory, maxBytes: 200, keepBytes: 600))
        #expect(try await box.agentLog(agent).hasPrefix(PersistentAgentShell.rotatedLine + "\n"))

        let session = try await box.session(for: agent)
        session.attach()
        defer { session.detach() }
        #expect(try await eventually(seconds: 20) { session.link.isLive && session.receivedBytes == total })
        #expect(session.assistantTexts.last?.hasSuffix(": cuatro") == true, "\(session.assistantTexts)")
        // Estable: ni se reengancha ni cuenta de más (la marca inicial no llega).
        let items = session.state.items.count
        try await Task.sleep(for: .seconds(2))
        #expect(session.link.isLive && session.receivedBytes == total && session.state.items.count == items)
    }

    @Test("Enviar justo cuando el vigilante quiere hibernar: o llega y no hiberna, o responde muerto y se reanuda",
          .timeLimit(.minutes(3)))
    func sendRacingWatchdog() async throws {
        let box = try await RemoteBox.open("agent-send-watch")
        // Vigilante muy agresivo: hiberna con 1 s de quietud, mirando cada segundo.
        let agent = try await box.launchAgent(hibernation: PersistentAgentHibernation(idleSeconds: 1, checkSeconds: 1))
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let session = try await box.session(for: agent, hibernation: PersistentAgentHibernation(idleSeconds: 1, checkSeconds: 1))
        for index in 1...6 {
            let word = "mensaje-\(index)"
            #expect(await session.send(word) == .sent, "Error: \(session.lastError ?? "-")")
            // Ningún mensaje dado por enviado se pierde: claude lo recibe (aunque se hibernara).
            #expect(try await eventually(seconds: 30) { try await box.agentLog(agent).contains(": \(word)") },
                    "Se perdió \(word)")
            try await Task.sleep(for: .milliseconds(300 * index))
        }
    }
}

}
