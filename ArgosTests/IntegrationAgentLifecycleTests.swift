//
//  IntegrationAgentLifecycleTests.swift
//  ArgosTests
//
//  Ciclo de vida de los agentes persistentes contra un servidor real con el `claude`
//  simulado: parar el GRUPO con TERM y escalado a KILL (sin tocar procesos ajenos),
//  «Detener todos» con uno atascado, hibernación manual y por vigilante (acelerado),
//  vigilante que respeta un grupo ocupado, reanudación con `--resume`, rotación del log
//  con un enganche vivo e inventario con memoria residente.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Agentes persistentes: ciclo de vida")
@MainActor
struct AgentLifecycle {

    /// Proceso testigo AJENO al agente (otro grupo, otra sesión): nunca debe morir.
    private func startWitness(_ box: RemoteBox, token: String) async throws -> String {
        try await box.sh("sh -c 'while :; do sleep 1; done' argos-it-witness-\(token) >/dev/null 2>&1 </dev/null & echo $!")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isRunning(_ box: RemoteBox, pid: String) async throws -> Bool {
        try await box.sh("kill -0 \(pid) 2>/dev/null && echo si; true").contains("si")
    }

    @Test("Parar con TERM mata el grupo entero (también el hijo en segundo plano) y no al testigo",
          .timeLimit(.minutes(2)))
    func stopKillsGroupButNotWitness() async throws {
        let box = try await RemoteBox.open("agent-stop")
        let agent = try await box.launchAgent(modes: ["spawn-child"])
        let witness = try await startWitness(box, token: agent.token)
        defer { IntegrationCleanup.later { _ = try? await box.sh("kill \(witness) 2>/dev/null; true"); await box.removeAgents([agent]); await box.close() } }
        #expect(try await eventually(seconds: 10) { try await !box.processes(matching: agent.childPattern).isEmpty })

        let session = try await box.session(for: agent)
        #expect(await session.stop())
        #expect(try await box.isAlive(agent) == false)
        #expect(try await box.exists(box.absolute(agent.workingDirectory)), "Parar sin borrar conserva la carpeta")
        if IntegrationRemote.isLinux {
            // Con setsid el agente lidera su grupo: el hijo muere con él.
            #expect(try await eventually(seconds: 5) { try await box.processes(matching: agent.childPattern).isEmpty },
                    "El hijo en segundo plano sobrevivió a la parada")
        }
        #expect(try await isRunning(box, pid: witness), "La parada mató un proceso ajeno")

        #expect(await session.stop(delete: true))
        #expect(try await box.sh("[ -d \(agent.directory) ] && echo existe; true").isEmpty)
    }

    @Test("Un agente que ignora TERM recibe KILL tras la espera", .timeLimit(.minutes(1)))
    func stopEscalatesToKill() async throws {
        let box = try await RemoteBox.open("agent-kill")
        let agent = try await box.launchAgent(modes: ["ignore-term"])
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let start = ContinuousClock.now
        try await box.sh(PersistentAgentScript.stop(id: agent.id, delete: false, graceSeconds: 2))
        #expect(try await box.isAlive(agent) == false)
        #expect(ContinuousClock.now - start >= .seconds(2), "Debe esperar la gracia antes del KILL")
    }

    @Test("«Detener todos» con uno que ignora TERM: paran todos y no se informa de fallos", .timeLimit(.minutes(2)))
    func stopAllWithOneStuck() async throws {
        let box = try await RemoteBox.open("agent-stopall")
        let normal = try await box.launchAgent(modes: ["spawn-child"])
        let stubborn = try await box.launchAgent(modes: ["ignore-term", "spawn-child"])
        let witness = try await startWitness(box, token: normal.token)
        defer { IntegrationCleanup.later { _ = try? await box.sh("kill \(witness) 2>/dev/null; true"); await box.removeAgents([normal, stubborn]); await box.close() } }

        let start = ContinuousClock.now
        let output = try await box.sh(ServerAgentInventory.stopPersistent(ids: [stubborn.id, normal.id]))
        #expect(ServerAgentInventory.failures(in: output).isEmpty, "Salida: \(output)")
        #expect(ContinuousClock.now - start < .seconds(PersistentAgentShell.stopGraceSeconds + 15))
        #expect(try await box.isAlive(normal) == false)
        #expect(try await box.isAlive(stubborn) == false)
        if IntegrationRemote.isLinux {
            for agent in [normal, stubborn] {
                #expect(try await eventually(seconds: 5) { try await box.processes(matching: agent.childPattern).isEmpty })
            }
        }
        #expect(try await isRunning(box, pid: witness))
    }

    @Test("Hibernar a demanda solo si está quieto; escribirle lo reanuda con --resume", .timeLimit(.minutes(4)))
    func manualHibernateAndResumeOnSend() async throws {
        let box = try await RemoteBox.open("agent-hib")
        let agent = try await box.launchAgent()
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let session = try await box.session(for: agent)
        #expect(await session.send("antes") == .sent)
        #expect(try await eventually(seconds: 15) { try await box.agentLog(agent).contains(": antes") })

        // Recién usado: con una hora de inactividad exigida, no se hiberna.
        let refused = try await box.sh(PersistentAgentScript.hibernate(id: agent.id, minIdleSeconds: 3600))
        #expect(!refused.contains(PersistentAgentScript.hibernatedReply))
        #expect(try await box.isAlive(agent))

        // Con 1 s de inactividad exigida acaba hibernándolo: se reintenta hasta que el log
        // lleve ese tiempo quieto (sin un `sleep` fijo que dependa de la carga).
        var done = ""
        #expect(try await eventually(seconds: 60) {
            done = try await box.sh(PersistentAgentScript.hibernate(id: agent.id, minIdleSeconds: 1))
            return done.contains(PersistentAgentScript.hibernatedReply)
        })
        #expect(done.contains("\(PersistentAgentScript.hibernatedReply) \(agent.id)"))
        #expect(try await box.isAlive(agent) == false)
        #expect(try await box.agentMeta(agent).contains("\"hibernatedAt\""))

        // La app ve que está hibernado y, al escribirle, lo reanuda sola.
        #expect(try await session.refreshInfo())
        #expect(session.meta.isHibernated && session.isAlive == false)
        #expect(await session.send("despierta") == .sent, "Error: \(session.lastError ?? "-")")
        #expect(try await box.isAlive(agent))
        #expect(try await eventually(seconds: 15) { try await box.agentLog(agent).contains(": despierta") })
        let calls = try await box.fakeCalls(agent).filter { $0.hasPrefix("args ") }
        #expect(calls.count == 2 && calls.last?.contains("--resume \(agent.id)") == true, "\(calls)")
        #expect(try await box.agentMeta(agent).contains("hibernatedAt") == false)
    }

    @Test("El vigilante hiberna un agente quieto (plazos acelerados)", .timeLimit(.minutes(2)))
    func watchdogHibernatesIdleAgent() async throws {
        let box = try await RemoteBox.open("agent-watch")
        let agent = try await box.launchAgent(hibernation: PersistentAgentHibernation(idleSeconds: 2, checkSeconds: 1))
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        #expect(try await eventually(seconds: 30) { try await !box.isAlive(agent) }, "No se hibernó")
        #expect(try await box.agentMeta(agent).contains("\"hibernatedAt\""))
        // El vigilante termina con él (no queda un sh esperando para siempre).
        #expect(try await eventually(seconds: 10) {
            try await box.processes(matching: "argos-watch").filter { $0.contains(agent.id) }.isEmpty
        })
    }

    @Test("El vigilante NO hiberna si el grupo del agente gasta CPU",
          .enabled(if: IntegrationRemote.isLinux, IntegrationRemote.linuxOnly), .timeLimit(.minutes(2)))
    func watchdogSparesBusyGroup() async throws {
        let box = try await RemoteBox.open("agent-busy")
        let agent = try await box.launchAgent(
            modes: ["busy-child"], hibernation: PersistentAgentHibernation(idleSeconds: 2, checkSeconds: 5)
        )
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        try await Task.sleep(for: .seconds(17))
        #expect(try await box.isAlive(agent), "Se hibernó con un hijo trabajando")
        #expect(try await box.agentMeta(agent).contains("hibernatedAt") == false)
        try await box.sh(PersistentAgentScript.stop(id: agent.id, delete: false, graceSeconds: 2))
        #expect(try await eventually(seconds: 5) { try await box.processes(matching: agent.childPattern).isEmpty })
    }

    @Test("Rotar el log con un enganche vivo: se reengancha sin perder ni repetir", .timeLimit(.minutes(2)))
    func rotationWithLiveAttach() async throws {
        let box = try await RemoteBox.open("agent-rotate")
        let agent = try await box.launchAgent()
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let session = try await box.session(for: agent)
        session.attach()
        defer { session.detach() }
        for word in ["uno", "dos", "tres"] {
            #expect(await session.send(word) == .sent)
            #expect(try await eventually(seconds: 15) { session.assistantTexts.contains { $0.hasSuffix(": \(word)") } })
        }
        let items = session.state.items.count
        try await box.sh(PersistentAgentScript.stop(id: agent.id, delete: false, graceSeconds: 2))
        let before = try await box.sh("wc -c < \(agent.directory)/out.ndjson | tr -d ' '")
        let total = try #require(Int(before.trimmingCharacters(in: .whitespacesAndNewlines)))

        // La rotación del lanzador (con el agente parado), con umbrales diminutos.
        try await box.sh(PersistentAgentShell.rotateOutputLog(agent.directory, maxBytes: 200, keepBytes: 400))
        let base = try await box.sh("cat \(agent.directory)/log.base")
        let rotated = try #require(Int(base.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(rotated > 0 && rotated < total)
        #expect(try await box.agentLog(agent).contains(PersistentAgentShell.rotatedEventType) == false)

        // El enganche vio la marca, se reenganchó y sigue en el mismo byte absoluto.
        #expect(try await eventually(seconds: 20) { session.link.isLive && session.receivedBytes == total })
        #expect(session.state.items.count == items, "La conversación no debe repetirse")

        // Lo nuevo que escriba el agente llega.
        let extra = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"tras rotar"}]}}"#
        try await box.sh("printf '%s\\n' \(box.q(extra)) >> \(agent.directory)/out.ndjson")
        #expect(try await eventually(seconds: 15) { session.assistantTexts.last == "tras rotar" })

        // Reanudar tras la rotación usa --resume y conserva el desplazamiento absoluto.
        #expect(await session.resume(oauthToken: nil))
        #expect(try await box.fakeCalls(agent).last { $0.hasPrefix("args ") }?.contains("--resume") == true)
        let listed = try await PersistentAgentSession.list(service: box.service).first { $0.id == agent.id }
        #expect((listed?.logBytes ?? 0) >= total)
    }

    @Test("Inventario del servidor: agentes vivos con memoria residente y memoria libre", .timeLimit(.minutes(1)))
    func inventory() async throws {
        let box = try await RemoteBox.open("agent-inv")
        let first = try await box.launchAgent(title: "primero")
        let second = try await box.launchAgent(title: "segundo")
        defer { IntegrationCleanup.later { await box.removeAgents([first, second]); await box.close() } }
        try await box.sh(PersistentAgentScript.stop(id: second.id, delete: false, graceSeconds: 2))

        let inventory = try await box.service.serverAgentInventory()
        let alive = try #require(inventory.agents.first { $0.sessionID == first.id })
        let stopped = try #require(inventory.agents.first { $0.sessionID == second.id })
        #expect(alive.isAlive && alive.residentKB > 0 && alive.title == "primero")
        #expect(stopped.isAlive == false && stopped.residentKB == 0)
        #expect(alive.idleSeconds.map { $0 >= 0 } == true)
        // Los persistentes no aparecen además como conversaciones del panel.
        #expect(inventory.agents.filter { $0.sessionID == first.id }.count == 1)
        if IntegrationRemote.isLinux {
            #expect((inventory.freeMemoryKB ?? 0) > 0)
        }
    }
}

}
