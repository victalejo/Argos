//
//  AgentHardeningRound2Tests.swift
//  ArgosTests
//
//  Segunda ronda: carrera del registro de huérfanos, `interrupt` sin turno activo, ruido
//  del perfil del shell, plazo de las respuestas, rotación vista desde el cliente,
//  reanudar sin reengancharse a escondidas y reanudar en el Mac sin dos claude.
//

import Foundation
import Testing
@testable import Argos

@Suite("Enganche: clasificación de líneas")
struct AgentAttachStreamParserTests {

    @Test func elRuidoAntesDeLaCabeceraNoCuenta() {
        var parser = AgentAttachStreamParser()
        #expect(parser.classify(text: "Bienvenido a Ubuntu 24.04") == .noise)
        #expect(parser.classify(text: nil) == .noise)
        #expect(parser.classify(text: #"{"type":"argos_log_base","base":7,"from":3}"#) == .header(base: 7, from: 3))
        #expect(parser.classify(text: #"{"type":"assistant"}"#) == .data)
        #expect(parser.classify(text: "texto suelto") == .data) // tras la cabecera, todo es log
    }

    @Test func sinCabeceraLaPrimeraLineaJSONEmpiezaLosDatos() {
        var parser = AgentAttachStreamParser()
        #expect(parser.classify(text: "ruido") == .noise)
        #expect(parser.classify(text: #"{"type":"system","subtype":"init"}"#) == .data)
    }

    @Test func trasLaMarcaDeRotacionSeIgnoraTodo() {
        var parser = AgentAttachStreamParser()
        _ = parser.classify(text: #"{"type":"argos_log_base","base":0,"from":1}"#)
        #expect(parser.classify(text: PersistentAgentShell.rotatedLine) == .rotated)
        #expect(parser.classify(text: #"{"type":"assistant"}"#) == .noise)
        // Un texto que solo menciona la marca no lo es.
        var other = AgentAttachStreamParser()
        _ = other.classify(text: #"{"type":"argos_log_base","base":0,"from":1}"#)
        #expect(other.classify(text: #"{"type":"assistant","text":"argos_log_rotated"}"#) == .data)
    }
}

@MainActor
@Suite("Agentes: segunda ronda de endurecimiento")
struct AgentHardeningRound2Tests {

    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    private func info(alive: Bool = true, logBytes: Int = 0) -> PersistentAgentInfo {
        PersistentAgentInfo(id: id, isAlive: alive, logBytes: logBytes,
                            meta: PersistentAgentMeta(workingDirectory: "/srv", title: "srv", createdAt: Date()))
    }

    @Test func laLimpiezaNoBorraDelRegistroUnaConversacionRecienCreada() async throws {
        let registry = AgentPanelRegistry(suiteName: "argos-test-race-\(UUID())")
        let store = AgentSessionStore(registry: registry)
        let serverID = UUID()
        let old = "11111111-2222-3333-4444-555555555555"
        let fresh = "22222222-2222-3333-4444-555555555555"
        registry.record(old, serverID: serverID)
        let mock = MockSSHService()
        // Mientras el servidor responde al inventario, se abre una pestaña nueva.
        mock.agentScriptOutput = { command in
            if command.contains("MEM|") { registry.record(fresh, serverID: serverID) }
            return ""
        }
        await store.cleanUpOrphans(serverID: serverID, service: mock)
        #expect(registry.sessionIDs(serverID: serverID).contains(fresh))
        #expect(!registry.sessionIDs(serverID: serverID).contains(old)) // ya no corre
    }

    @Test func detenerSinTurnoActivoNoSeQuedaBloqueado() async throws {
        let mock = MockSSHService()
        let session = ClaudeAgentSession(service: mock, command: "claude", workingDirectory: "/srv", oauthToken: nil, sessionID: "s1")
        session.sendUserText("algo")
        session.interrupt()
        #expect(session.isInterrupting)
        try await waitUntil { mock.agentStdinLines.contains { $0.contains("\"interrupt\"") } }
        let line = try #require(mock.agentStdinLines.last { $0.contains("\"interrupt\"") })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let requestID = try #require(object["request_id"] as? String)
        // Otra respuesta de control no lo reinicia…
        session.handle(line: #"{"type":"control_response","response":{"subtype":"success","request_id":"otra"}}"#)
        #expect(session.isInterrupting)
        // …la de SU interrupt sí, aunque no llegue ningún `result` (no había turno).
        session.handle(line: #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(requestID)","response":{"still_queued":[]}}}"#)
        #expect(!session.isInterrupting)

        // Y un prompt nuevo también lo reinicia aunque no llegue respuesta.
        session.interrupt()
        session.sendUserText("otra cosa")
        #expect(!session.isInterrupting)
        session.stop()
    }

    @Test func elRuidoDelPerfilNoConfundeAlLanzador() async throws {
        let mock = MockSSHService()
        mock.agentScript = ["Bienvenido a Ubuntu", "Last login: ayer", "4242"]
        let session = try await PersistentAgentSession.launch(service: mock, workingDirectory: "/srv", title: "t", oauthToken: nil)
        #expect(session.isAlive)
        #expect(!PersistentAgentSession.isLaunchReply("Bienvenido"))
        #expect(PersistentAgentSession.isLaunchReply("ARGOS_AGENT_FAILED abc"))
    }

    @Test func sinRespuestaVenceElPlazo() async {
        let mock = MockSSHService() // no imprime nada y espera a stdin
        await #expect(throws: AgentExchangeTimeout()) {
            _ = try await AgentStdinExchange.firstLine(service: mock, command: "x", input: [], timeout: .milliseconds(300))
        }
    }

    @Test func laMarcaDeRotacionCortaElEngancheYReengancha() async throws {
        let mock = MockSSHService()
        let prompt = #"{"type":"user","message":{"role":"user","content":"hola"}}"#
        let copy = #"{"type":"assistant","message":{"content":[{"type":"text","text":"copia"}]}}"#
        mock.agentScript = ["Bienvenido", #"{"type":"argos_log_base","base":0,"from":1}"#, prompt,
                            PersistentAgentShell.rotatedLine, prompt, copy]
        let session = PersistentAgentSession(service: mock, info: info(), hibernation: { .standard })
        session.attach()
        try await waitUntil { session.receivedBytes == prompt.utf8.count + 1 }
        // Lo que responderá el servidor tras la rotación: nada nuevo desde ahí.
        mock.agentScript = [#"{"type":"argos_log_base","base":0,"from":\#(prompt.utf8.count + 2)}"#]
        try await waitUntil { mock.agentCommands.count >= 2 } // se reenganchó solo
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state.items.map(\.kind) == [.userText("hola")]) // la copia no se duplica
        #expect(session.receivedBytes == prompt.utf8.count + 1) // ni ruido ni marca ni copia
        #expect(mock.agentCommands.last?.contains("s=$((\(prompt.utf8.count + 2) - b))") == true)
        session.detach()
    }

    @Test func reanudarConLaVistaCerradaNoSeReengancha() async throws {
        let mock = MockSSHService()
        mock.agentScript = ["4242"]
        let session = PersistentAgentSession(service: mock, info: info(alive: false, logBytes: 10), hibernation: { .standard })
        #expect(await session.resume(oauthToken: nil))
        try await Task.sleep(for: .milliseconds(200))
        #expect(mock.agentCommands.count == 1) // solo el lanzador
        #expect(session.link == .detached)
    }

    @Test func recargarEmpiezaDesdeCero() async throws {
        let mock = MockSSHService()
        let prompt = #"{"type":"user","message":{"role":"user","content":"hola"}}"#
        mock.agentScript = [#"{"type":"argos_log_base","base":0,"from":1}"#, prompt]
        let session = PersistentAgentSession(service: mock, info: info(), hibernation: { .standard })
        session.attach()
        try await waitUntil { session.state.items.count == 1 }
        session.reload()
        try await waitUntil { session.state.items.count == 1 && mock.agentCommands.count == 2 }
        #expect(mock.agentCommands.last?.contains("s=$((1 - b))") == true)
        session.detach()
    }

    @Test func reanudarEnElMacMataAntesElClaudeAnterior() async throws {
        let mock = MockSSHService()
        let store = AgentSessionStore(registry: AgentPanelRegistry(suiteName: "argos-test-resume-\(UUID())"))
        let handle = SessionHandle(serverID: UUID(), sessionID: "p")
        let sessionID = "33333333-2222-3333-4444-555555555555"
        let tab = store.newTab(for: handle, service: mock, command: "c", workingDirectory: "/srv",
                               oauthToken: nil, permissionMode: .default, sessionID: sessionID)
        tab.session.sendUserText("hola")
        tab.session.stop() // p. ej. se cortó la conexión
        try await waitUntil { !mock.agentScripts.isEmpty }
        let killsBefore = mock.agentScripts.count
        await store.resumeTab(tab.id, for: handle, service: mock, command: "claude --resume \(sessionID)", oauthToken: nil)
        // Antes de lanzar el nuevo, se buscó y mató cualquier claude con ese id.
        #expect(mock.agentScripts.count > killsBefore)
        #expect(mock.agentScripts.last?.contains(sessionID) == true)
        try await waitUntil { mock.agentCommands.contains("claude --resume \(sessionID)") }
        let resumed = try #require(store.tabs(for: handle).first)
        #expect(resumed.id == tab.id && resumed.session.isRunning)
        #expect(resumed.session.state.items.map(\.kind) == [.userText("hola")])
        store.closeAll(for: handle)
    }
}
