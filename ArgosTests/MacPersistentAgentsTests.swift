//
//  MacPersistentAgentsTests.swift
//  ArgosTests
//
//  Agentes persistentes en el panel Agente del Mac: el adaptador común de las dos clases
//  de conversación, qué pasa al cerrar una pestaña, el log inicial de «Continuar en el
//  servidor», la conversión en el store (contra el mock), el listado de agentes del
//  servidor, la bandeja de atención y la elección «solo en esta sesión / en el servidor».
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Mac: agentes persistentes")
struct MacPersistentAgentsTests {

    private let agentID = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private let serverID = UUID()
    private var handle: SessionHandle { SessionHandle(serverID: serverID, sessionID: "web") }

    private func store() -> AgentSessionStore {
        AgentSessionStore(registry: AgentPanelRegistry(suiteName: "argos-test-mac-persistent-\(UUID())"))
    }

    private func meta(mode: ClaudeAgentCommand.PermissionMode = .default, hibernated: Bool = false, folder: String = "/srv/web") -> PersistentAgentMeta {
        PersistentAgentMeta(workingDirectory: folder, title: "web", createdAt: Date(), permissionMode: mode.rawValue,
                            hibernatedAt: hibernated ? Date() : nil)
    }

    private func info(alive: Bool = true, logBytes: Int = 0, mode: ClaudeAgentCommand.PermissionMode = .default, hibernated: Bool = false) -> PersistentAgentInfo {
        PersistentAgentInfo(id: agentID, isAlive: alive, logBytes: logBytes, meta: meta(mode: mode, hibernated: hibernated))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    // MARK: - Adaptador común

    @Test("Fase de una conversación de esta sesión")
    func sessionPhase() {
        #expect(AgentConversationPhase.session(status: .idle, hasPendingPermission: false, lostConnection: false) == .ready)
        #expect(AgentConversationPhase.session(status: .working, hasPendingPermission: false, lostConnection: false) == .working)
        #expect(AgentConversationPhase.session(status: .working, hasPendingPermission: true, lostConnection: false) == .awaitingPermission)
        #expect(AgentConversationPhase.session(status: .finished, hasPendingPermission: false, lostConnection: false) == .stopped(.ended))
        #expect(AgentConversationPhase.session(status: .failed("x"), hasPendingPermission: false, lostConnection: true) == .stopped(.connectionLost))
    }

    @Test("Fase de un agente persistente: vivo, en reposo, detenido y reanudando")
    func persistentPhase() {
        func phase(alive: Bool, hibernated: Bool = false, resuming: Bool = false, status: AgentStatus = .idle, permission: Bool = false) -> AgentConversationPhase {
            .persistent(isAlive: alive, isHibernated: hibernated, isResuming: resuming, status: status, hasPendingPermission: permission)
        }
        #expect(phase(alive: true) == .ready)
        #expect(phase(alive: true, status: .working) == .working)
        #expect(phase(alive: true, status: .working, permission: true) == .awaitingPermission)
        #expect(phase(alive: false, hibernated: true) == .asleep)
        #expect(phase(alive: false) == .stopped(.agentStopped))
        #expect(phase(alive: false, resuming: true) == .resuming)
        #expect(AgentConversationPhase.asleep.acceptsMessages, "Escribir a uno en reposo lo reanuda")
        #expect(!AgentConversationPhase.working.acceptsMessages)
        #expect(!AgentConversationPhase.stopped(.agentStopped).acceptsMessages)
    }

    @Test("Las dos clases de sesión cumplen el protocolo con su ciclo de vida")
    func adapterConformances() async throws {
        let mock = MockSSHService()
        let panel = ClaudeAgentSession(service: mock, command: "claude", workingDirectory: "/srv/web", oauthToken: nil, sessionID: agentID)
        let panelDriver: any AgentConversationDriving = panel
        #expect(panelDriver.lifecycle == .session)
        #expect(panelDriver.phase == .ready)
        #expect(await panelDriver.submit("hola", confirmedResume: false) == .sent)
        #expect(panelDriver.state.items.map(\.kind) == [.userText("hola")])
        #expect(panelDriver.phase == .working)
        #expect(await panelDriver.submit("otra", confirmedResume: false) == .failed, "Mientras trabaja no se envía")
        panel.stop()

        let persistent = PersistentAgentSession(service: mock, info: info(alive: false, mode: .bypassPermissions, hibernated: true), hibernation: { .standard })
        let driver: any AgentConversationDriving = persistent
        #expect(driver.lifecycle == .persistent)
        #expect(driver.workingDirectory == "/srv/web")
        #expect(driver.phase == .asleep)
        #expect(driver.resumeConfirmationMode == .bypassPermissions)
        #expect(driver.connectionNotice == nil, "Sin enganche no hay aviso de conexión")
        #expect(await driver.submit("sigue", confirmedResume: false) == .needsResumeConfirmation)
    }

    @Test("Detener el turno de un persistente manda «interrupt» por la FIFO; con permiso pendiente no")
    func persistentInterrupt() async throws {
        let mock = MockSSHService()
        let prompt = #"{"type":"user","message":{"role":"user","content":"haz algo"}}"#
        mock.agentScript = [#"{"type":"argos_log_base","base":0,"from":1}"#, prompt]
        let session = PersistentAgentSession(service: mock, info: info(), hibernation: { .standard })
        session.attach()
        try await waitUntil { session.state.status == .working }
        await session.interruptTurn()
        #expect(session.isInterrupting)
        #expect(mock.agentScripts.contains { $0.contains("in") && $0.contains("base64 -d >&3") })
        session.detach()
    }

    // MARK: - Cerrar

    @Test("Cerrar la pestaña de un persistente nunca lo detiene; una de esta sesión, sí")
    func closePolicy() {
        #expect(AgentTabClosePolicy.decide(lifecycle: .persistent, isBusy: true) == .detach)
        #expect(AgentTabClosePolicy.decide(lifecycle: .persistent, isBusy: false) == .detach)
        #expect(AgentTabClosePolicy.decide(lifecycle: .session, isBusy: true) == .confirmStop)
        #expect(AgentTabClosePolicy.decide(lifecycle: .session, isBusy: false) == .stop)
    }

    @Test("El store cierra la pestaña persistente sin pararlo y stopAll no lo toca")
    func storeKeepsPersistentAlive() async throws {
        let mock = MockSSHService()
        let store = store()
        let tabID = store.openPersistent(info(), for: handle, service: mock)
        #expect(store.slots(for: handle).first?.lifecycle == .persistent)
        #expect(store.allTabs.isEmpty, "Los persistentes no cuentan como conversaciones de esta sesión")
        #expect(store.liveCount == 0)
        // Abrirlo otra vez no duplica la pestaña.
        #expect(store.openPersistent(info(), for: handle, service: mock) == tabID)
        #expect(store.slots(for: handle).count == 1)

        await store.stopAll()
        store.closeTab(tabID, for: handle)
        #expect(store.slots(for: handle).isEmpty)
        let stops = mock.agentScripts.filter { $0.contains("kill") || $0.contains("rm -rf") }
        #expect(stops.isEmpty, "Cerrar o salir no debe parar un persistente: \(stops)")
        #expect(store.closedConversations(for: handle).isEmpty)
    }

    // MARK: - Continuar en el servidor

    @Test("Qué impide pasar una conversación al servidor")
    func conversionBlocker() {
        #expect(AgentConversion.blocker(hasConversation: false, isBusy: false, sessionID: agentID) == .nothingToContinue)
        #expect(AgentConversion.blocker(hasConversation: true, isBusy: false, sessionID: "no-uuid") == .nothingToContinue)
        #expect(AgentConversion.blocker(hasConversation: true, isBusy: true, sessionID: agentID) == .busy)
        #expect(AgentConversion.blocker(hasConversation: true, isBusy: false, sessionID: agentID) == nil)
    }

    private func sampleState() -> AgentConversationState {
        var state = AgentConversationState()
        AgentReducer.userSent(text: "revisa el código", to: &state)
        AgentReducer.apply(.assistant([.thinking("pienso"), .text("Voy a leerlo."),
                                       .toolUse(id: "t1", name: "Read", input: .object(["file_path": .string("/srv/web/a.swift")]))]), to: &state)
        AgentReducer.apply(.user([.toolResult(toolUseID: "t1", text: "línea 1\nlínea 2", isError: false)]), to: &state)
        AgentReducer.apply(.assistant([.text("Todo bien.")]), to: &state)
        AgentReducer.apply(.result(AgentResult(subtype: "success", isError: false, text: "Todo bien.", totalCostUSD: 0.01)), to: &state)
        return state
    }

    @Test("El log inicial reconstruye la misma conversación que se veía en el Mac")
    func seedReplaysTranscript() {
        let state = sampleState()
        let seed = AgentTranscriptSeed.make(from: state)
        #expect(seed.lines.allSatisfy { !$0.contains("\n") }, "Cada evento es una línea")
        #expect(seed.replayedState.items.map(\.kind) == state.items.map(\.kind))
        #expect(seed.replayedState.status == .idle)
        // Para los avisos del iPhone y el vigilante del servidor: terminó, no trabaja.
        #expect(AgentAttention.evaluate(logTail: seed.lines.joined(separator: "\n")) == .finished(summary: "Todo bien.", isError: false))
    }

    @Test("Una conversación cortada a medias se cierra con un result y sin copiar el error")
    func seedClosesUnfinishedTurn() {
        var state = AgentConversationState()
        AgentReducer.userSent(text: "hola", to: &state)
        AgentReducer.finished(error: "Se perdió la conexión", to: &state)
        let seed = AgentTranscriptSeed.make(from: state)
        #expect(seed.lines.count == 2)
        #expect(seed.lines.last?.contains(AgentTranscriptSeed.closingSubtype) == true)
        #expect(seed.replayedState.status == .idle)
        #expect(!seed.replayedState.items.contains { if case .error = $0.kind { return true } else { return false } })
    }

    @Test("El log inicial respeta el tope conservando lo más reciente")
    func seedTrimsOldest() {
        var state = AgentConversationState()
        for index in 0..<50 { AgentReducer.userSent(text: "mensaje \(index) " + String(repeating: "x", count: 200), to: &state) }
        let seed = AgentTranscriptSeed.make(from: state, maxBytes: 2_000)
        #expect(seed.bytes.count <= 2_000)
        #expect(seed.lines.last?.contains(AgentTranscriptSeed.closingSubtype) == true)
        #expect(!seed.lines.isEmpty)
    }

    @Test("El script del log inicial crea la carpeta de forma atómica y comprueba los bytes")
    func seedScript() {
        let script = PersistentAgentScript.seed(id: agentID, byteCount: 1234)
        #expect(script.contains("( umask 077 && mkdir \"$HOME/.config/argos/agents/\(agentID)\" )"))
        #expect(script.contains(PersistentAgentScript.existsReply))
        #expect(script.contains("head -c 1234"))
        #expect(script.contains("[ ! -f \"$HOME/.config/argos/agents/\(agentID)\"/meta.json ]"), "Solo descarta carpetas a medias")
    }

    @Test("«Continuar en el servidor» para el claude de la sesión y relanza la conversación con --resume")
    func continueOnServerConvertsInPlace() async throws {
        let mock = MockSSHService()
        // Respuestas del log inicial y del lanzador (cada intercambio toma la suya).
        mock.agentScript = [PersistentAgentScript.seededReply, "4242"]
        let store = store()
        let tab = store.newTab(for: handle, service: mock, command: "claude", workingDirectory: "/srv/web",
                               oauthToken: nil, permissionMode: .acceptEdits, sessionID: agentID)
        tab.session.sendUserText("explica el proyecto")
        AgentReducerTestHook.finishTurn(tab.session)
        try await store.continueOnServer(tab.id, for: handle, service: mock, oauthToken: nil,
                                         claudePath: "/usr/bin/claude", hibernation: .standard)

        let slot = try #require(store.slots(for: handle).first)
        #expect(slot.id == tab.id, "Misma pestaña")
        let persistent = try #require(slot.persistentTab)
        #expect(persistent.session.id == agentID)
        #expect(persistent.session.meta.resolvedPermissionMode == .acceptEdits)
        #expect(persistent.session.state.items.first?.kind == .userText("explica el proyecto"), "No se pierde lo que se veía")
        #expect(store.allTabs.isEmpty)
        let commands = mock.agentCommands
        #expect(commands.contains { $0.contains("head -c") }, "Escribe el log inicial")
        #expect(commands.contains { $0.contains("--resume \(agentID)") && $0.contains("--replay-user-messages") })
        #expect(mock.agentScripts.contains { $0.contains(agentID) && $0.contains("pm()") }, "Para antes el claude del panel")
        #expect(store.closedConversations(for: handle).isEmpty)
        store.closeAll(for: handle)
    }

    // MARK: - Listado del servidor

    @Test("El listado de agentes interpreta estado, inactividad y el final del log")
    func overviewParsing() throws {
        let metaB64 = try JSONEncoder.projects.encode(meta()).base64EncodedString()
        let pending = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"#
        let tail = Data(pending.utf8).base64EncodedString()
        let done = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#.utf8).base64EncodedString()
        let other = "b1f0a2c3-0000-4000-8000-000000000001"
        let output = "\(agentID)|1|900|30|\(metaB64)|\(tail)\n\(other)|0|10|7200|\(metaB64)|\(done)\nbasura|x\n"
        let agents = PersistentAgentScript.parseOverview(output)
        #expect(agents.count == 2)
        let first = try #require(agents.first { $0.id == agentID })
        #expect(first.activity == .waitingPermission(tool: "Bash"))
        #expect(first.idleSeconds == 30)
        #expect(agents.first { $0.id == other }?.activity == .stopped)
        #expect(PersistentAgentScript.overview().contains("argos/agents"))
    }

    // MARK: - Bandeja de atención

    private func overview(bytes: Int, attention: AgentAttention, alive: Bool = true) -> PersistentAgentOverview {
        PersistentAgentOverview(id: agentID, isAlive: alive, logBytes: bytes, idleSeconds: 5, meta: meta(), attention: attention)
    }

    @Test("Terminó: entra cuando el log crece y acaba en un result; sale al mirarlo o al volver a trabajar")
    func trackerFinished() {
        var tracker = PersistentAgentAttentionTracker()
        let finished = AgentAttention.finished(summary: "ok", isError: false)
        tracker.absorb(serverID: serverID, agents: [overview(bytes: 100, attention: finished)])
        #expect(tracker.unseenDone.isEmpty, "La primera vuelta solo toma referencia")
        tracker.absorb(serverID: serverID, agents: [overview(bytes: 200, attention: finished)])
        #expect(tracker.unseenDone.count == 1)
        tracker.absorb(serverID: serverID, agents: [overview(bytes: 300, attention: .none)])
        #expect(tracker.unseenDone.isEmpty, "Volvió a trabajar")
        tracker.absorb(serverID: serverID, agents: [overview(bytes: 400, attention: finished)])
        tracker.absorb(serverID: serverID, agents: [overview(bytes: 400, attention: finished)], viewing: [agentID])
        #expect(tracker.unseenDone.isEmpty, "Con la pestaña enganchada ya se está mirando")
        tracker.absorb(serverID: serverID, agents: [overview(bytes: 500, attention: finished)])
        tracker.markSeen(serverID: serverID, agentID: agentID)
        #expect(tracker.unseenDone.isEmpty)
    }

    @Test("Permisos pendientes de persistentes en la bandeja, con su proyecto y su destino")
    func trackerPermissionInAttentionList() {
        var tracker = PersistentAgentAttentionTracker()
        let agents = [serverID: [overview(bytes: 10, attention: .needsPermission(tool: "Bash"))]]
        tracker.absorb(serverID: serverID, agents: agents[serverID] ?? [])
        let notices = tracker.notices(agents: agents)
        #expect(notices.count == 1)
        #expect(tracker.notices(agents: agents, excluding: [agentID]).isEmpty, "La pestaña abierta ya lo muestra")

        let web = Project(name: "Web", path: "/srv/web/")
        let items = AttentionList.build(
            inbox: AttentionInbox(),
            servers: [.init(serverID: serverID, claude: .empty, projects: [web])],
            persistentAgents: notices
        )
        #expect(items.count == 1)
        #expect(items.first?.kind == .agentPermission)
        #expect(items.first?.needsResponse == true)
        #expect(items.first?.title == "Web")
        #expect(items.first?.destination == .persistentAgent(serverID: serverID, agentID: agentID))
    }

    @Test("Un agente terminado sin mirar entra como «Claude terminó» informativo")
    func finishedNoticeInAttentionList() {
        let notice = PersistentAgentAttentionTracker.Notice(
            serverID: serverID, agentID: agentID, title: "web", workingDirectory: "/otra",
            kind: .finished(summary: "Hecho", isError: false)
        )
        let items = AttentionList.build(inbox: AttentionInbox(), servers: [], persistentAgents: [notice])
        #expect(items.first?.kind == .claudeDone)
        #expect(items.first?.needsResponse == false)
        #expect(items.first?.detail.contains("Hecho") == true)
    }

    // MARK: - Preferencias

    @Test("Dónde vive una conversación nueva se recuerda por proyecto; por defecto, solo en esta sesión")
    func placementPreference() throws {
        let defaults = try #require(UserDefaults(suiteName: "argos-test-placement-\(UUID())"))
        #expect(AgentLaunchPreferences.placement(serverID: serverID, workingDirectory: "/srv/web", defaults: defaults) == .session)
        AgentLaunchPreferences.setPlacement(.server, serverID: serverID, workingDirectory: "/srv/web/", defaults: defaults)
        #expect(AgentLaunchPreferences.placement(serverID: serverID, workingDirectory: "/srv/web", defaults: defaults) == .server)
        #expect(AgentLaunchPreferences.placement(serverID: serverID, workingDirectory: "/srv/api", defaults: defaults) == .session)
        #expect(AgentLaunchPreferences.stored("otra-cosa") == .session)
        #expect(!AgentLaunchPreferences.key(serverID: serverID, workingDirectory: "/a.b").contains("."))
    }
}

/// Cierra el turno de una sesión del panel como lo haría el CLI (para poder convertirla).
@MainActor
enum AgentReducerTestHook {
    static func finishTurn(_ session: ClaudeAgentSession) {
        session.handle(line: #"{"type":"result","subtype":"success","is_error":false,"result":"listo"}"#)
    }
}
