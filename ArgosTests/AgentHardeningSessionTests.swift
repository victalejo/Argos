//
//  AgentHardeningSessionTests.swift
//  ArgosTests
//
//  Clientes de agente contra el mock: enganche incremental, envío grande por stdin,
//  reanudación automática de un agente hibernado, borrador que no se pierde, y en el
//  panel del Mac: interrumpir, reanudar, `stopAll` y limpieza de huérfanos.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Agente persistente: cliente endurecido")
struct PersistentAgentSessionHardeningTests {

    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"

    private func info(alive: Bool = true, logBytes: Int = 0, mode: String? = nil, hibernated: Bool = false) -> PersistentAgentInfo {
        PersistentAgentInfo(
            id: id, isAlive: alive, logBytes: logBytes,
            meta: PersistentAgentMeta(workingDirectory: "/srv", title: "srv", createdAt: Date(),
                                      permissionMode: mode, hibernatedAt: hibernated ? Date() : nil)
        )
    }

    private func header(base: Int = 0, from: Int) -> String {
        #"{"type":"argos_log_base","base":\#(base),"from":\#(from)}"#
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<3000 where !condition() { try await Task.sleep(for: .milliseconds(20)) } // hasta 60 s
        #expect(condition())
    }

    @Test func reengancharSigueDesdeLoLeidoSinPerderLaConversacion() async throws {
        let mock = MockSSHService()
        let prompt = #"{"type":"user","message":{"role":"user","content":"hola"}}"#
        let answer = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hola."}]}}"#
        mock.agentScript = [header(from: 1), prompt, answer]
        let session = PersistentAgentSession(service: mock, info: info(), hibernation: { .standard })
        session.attach()
        try await waitUntil { session.state.items.count == 2 && session.link == .live }
        let read = prompt.utf8.count + answer.utf8.count + 2
        #expect(session.receivedBytes == read) // la cabecera no cuenta
        session.detach()
        #expect(session.link == .detached)

        // Segundo enganche: pide desde el byte siguiente y solo llega lo nuevo.
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#
        mock.agentScript = [header(from: read + 1), result]
        session.attach()
        try await waitUntil { session.state.items.count == 3 }
        #expect(mock.lastAgentCommand?.contains("s=$((\(read + 1) - b))") == true)
        #expect(session.state.items.map(\.kind).prefix(2) == [.userText("hola"), .assistantText("Hola.")])
        session.detach()

        // Si el servidor rotó lo que faltaba, se reconstruye desde lo conservado.
        mock.agentScript = [header(base: 10_000, from: 1), answer]
        session.attach()
        try await waitUntil { session.state.items.count == 1 }
        #expect(session.receivedBytes == 10_000 + answer.utf8.count + 1)
        session.detach()
    }

    @Test func unaRespuestaDePermisoEnormeViajaPorStdin() async throws {
        let mock = MockSSHService()
        mock.agentScript = [PersistentAgentScript.sentReply]
        let session = PersistentAgentSession(service: mock, info: info(), hibernation: { .standard })
        let input = JSONValue.object(["content": .string(String(repeating: "x", count: 150_000))])
        let request = AgentPermissionRequest(id: "r1", toolName: "Write", displayName: nil, input: input, toolUseID: nil)
        await session.respond(to: request, decision: .allow(updatedInput: input))
        let command = try #require(mock.lastAgentCommand)
        #expect(command.contains("head -n 1"))
        #expect(command.utf8.count < PersistentAgentScript.maxInlineCommandBytes)
        #expect(mock.agentStdinLines.last?.contains(String(repeating: "x", count: 150_000)) == true)
        #expect(mock.agentScripts.isEmpty) // nada por la línea de comandos
        #expect(session.lastError == nil)
    }

    @Test func unEnvioQueNoLlegaEnteroNoSeDaPorBueno() async {
        let mock = MockSSHService()
        mock.agentScript = [PersistentAgentScript.shortReply]
        let session = PersistentAgentSession(service: mock, info: info(), hibernation: { .standard })
        let outcome = await session.send(String(repeating: "y", count: 120_000))
        #expect(outcome == .failed)
        #expect(session.lastError == PersistentAgentError.truncatedSend.userMessage)
    }

    @Test func escribirAUnAgenteHibernadoLoReanudaSolo() async throws {
        let mock = MockSSHService()
        mock.agentScript = ["4242"]
        let session = PersistentAgentSession(service: mock, info: info(alive: false, logBytes: 512, hibernated: true),
                                             hibernation: { .standard })
        let outcome = await session.send("sigue")
        #expect(outcome == .sent)
        #expect(session.isAlive && !session.meta.isHibernated)
        #expect(mock.agentCommands.first?.contains("--resume \(id)") == true)
        #expect(mock.agentScripts.contains { $0.contains("exec 3<>") })
        session.detach()
    }

    @Test func hibernadoEnUnModoSinPreguntasPideConfirmar() async {
        let mock = MockSSHService()
        mock.agentScript = ["4242"]
        let session = PersistentAgentSession(
            service: mock, info: info(alive: false, logBytes: 9, mode: "bypassPermissions", hibernated: true),
            hibernation: { .standard }
        )
        #expect(await session.send("sigue") == .needsResumeConfirmation)
        #expect(mock.agentCommands.isEmpty) // no se reanudó sin permiso
        #expect(await session.send("sigue", confirmedResume: true) == .sent)
        #expect(mock.agentCommands.first?.contains("--resume") == true)
        session.detach()
    }

    @Test func unAgenteSinConversacionSeReanudaConSuMismoID() async {
        let mock = MockSSHService()
        mock.agentScript = ["4242"]
        let session = PersistentAgentSession(service: mock, info: info(alive: false, logBytes: 0, hibernated: true),
                                             hibernation: { .standard })
        await session.resume(oauthToken: nil)
        #expect(mock.agentCommands.first?.contains("--session-id \(id)") == true)
        session.detach()
    }

    @Test func siElEnvioFallaElMensajeNoSeDaPorEnviado() async {
        let mock = MockSSHService()
        mock.agentScriptOutput = { _ in throw AgentExecError(message: "sin cobertura") }
        let session = PersistentAgentSession(service: mock, info: info(), hibernation: { .standard })
        #expect(await session.send("hola") == .failed)
        #expect(session.state.status != .working)
        #expect(session.lastError?.contains("sin cobertura") == true)
    }

    @Test func elLanzadorQueFallaMuestraElErrorDelServidor() async {
        let mock = MockSSHService()
        let detail = Data("Error: not logged in".utf8).base64EncodedString()
        mock.agentScript = ["\(PersistentAgentScript.failedReply) \(detail)"]
        await #expect(throws: PersistentAgentError.launchFailed("Error: not logged in")) {
            _ = try await PersistentAgentSession.launch(service: mock, workingDirectory: "/", title: "x", oauthToken: nil)
        }
    }
}

@MainActor
@Suite("Panel Agente del Mac: interrumpir, reanudar y huérfanos")
struct AgentPanelHardeningTests {

    private let handle = SessionHandle(serverID: UUID(), sessionID: "tienda")

    private func store() -> AgentSessionStore {
        AgentSessionStore(registry: AgentPanelRegistry(suiteName: "argos-test-panel-\(UUID())"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<3000 where !condition() { try await Task.sleep(for: .milliseconds(20)) } // hasta 60 s
        #expect(condition())
    }

    @Test func detenerMandaLaPeticionInterruptYConservaLaConversacion() async throws {
        let mock = MockSSHService()
        let session = ClaudeAgentSession(service: mock, command: "claude", workingDirectory: "/srv", oauthToken: nil, sessionID: "s1")
        session.sendUserText("haz algo largo")
        #expect(session.state.status == .working)
        session.interrupt()
        #expect(session.isInterrupting)
        try await waitUntil { mock.agentStdinLines.contains { $0.contains("\"interrupt\"") } }
        #expect(session.state.items.count == 1) // la conversación sigue ahí
        #expect(session.isRunning)
        session.stop()
    }

    @Test func elTopeNoCierraNadaEnSilencio() {
        let mock = MockSSHService()
        let store = store()
        for _ in 0..<AgentSessionStore.maxLiveSessions {
            store.newTab(for: handle, service: mock, command: "c", workingDirectory: "/", oauthToken: nil, permissionMode: .default)
        }
        #expect(store.capacity == .full(limit: AgentSessionStore.maxLiveSessions))
        #expect(store.tabs(for: handle).count == AgentSessionStore.maxLiveSessions)
        if let first = store.tabs(for: handle).first { store.closeTab(first.id, for: handle) }
        #expect(store.capacity == .available)
        store.closeAll(for: handle)
    }

    @Test func cerrarRecuerdaLaConversacionYSePuedeReanudar() async throws {
        let mock = MockSSHService()
        let store = store()
        let tab = store.newTab(for: handle, service: mock, command: "c", workingDirectory: "/srv",
                               oauthToken: nil, permissionMode: .plan, sessionID: "AAAA-1")
        tab.session.sendUserText("explica el proyecto")
        store.closeTab(tab.id, for: handle)
        let closed = try #require(store.closedConversations(for: handle).first)
        #expect(closed.sessionID == "aaaa-1" && closed.permissionMode == .plan && closed.title == "explica el proyecto")

        let reopened = await store.reopen(closed, for: handle, service: mock, command: "claude --resume aaaa-1", oauthToken: nil)
        #expect(reopened.session.sessionID == "aaaa-1")
        #expect(reopened.session.state.items.map(\.kind) == [.userText("explica el proyecto")])
        #expect(store.closedConversations(for: handle).isEmpty)
        try await waitUntil { mock.agentCommands.contains("claude --resume aaaa-1") }
        store.closeAll(for: handle)
    }

    @Test func stopAllMataTodosLosClaudeYEspera() async throws {
        let mock = MockSSHService()
        mock.agentScript = [#"{"type":"argos_pid","pid":4321}"#]
        let store = store()
        let tab = store.newTab(for: handle, service: mock, command: "c", workingDirectory: "/", oauthToken: nil, permissionMode: .default)
        try await waitUntil { tab.session.remotePID == 4321 }
        await store.stopAll()
        // Se mata por su id de sesión (comprobado en cada señal), no por un PID a ciegas.
        #expect(mock.agentScripts.contains { $0.contains(tab.session.sessionID) && $0.contains("kill -s TERM") })
        #expect(!tab.session.isRunning)
    }

    @Test func alConectarMataSoloLosHuerfanosDeEsteDispositivo() async throws {
        let mock = MockSSHService()
        let registry = AgentPanelRegistry(suiteName: "argos-test-orph-\(UUID())")
        let store = AgentSessionStore(registry: registry)
        let orphan = "11111111-2222-3333-4444-555555555555"
        let foreign = "99999999-2222-3333-4444-555555555555"
        registry.record(orphan, serverID: handle.serverID)
        let args = "claude -p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio --permission-mode default --session-id"
        mock.agentScriptOutput = { command in
            command.contains("MEM|") ? "M|777|1000|\(args) \(orphan)\nM|778|1000|\(args) \(foreign)\n" : ""
        }
        await store.cleanUpOrphans(serverID: handle.serverID, service: mock)
        let kill = try #require(mock.agentScripts.last)
        #expect(kill.contains("777:\(orphan)") && kill.contains("kill -s TERM"))
        #expect(!kill.contains("778"))
        // Throttle: una segunda llamada inmediata no vuelve a ir al servidor.
        let count = mock.agentScripts.count
        await store.cleanUpOrphans(serverID: handle.serverID, service: mock)
        #expect(mock.agentScripts.count == count)
    }
}
