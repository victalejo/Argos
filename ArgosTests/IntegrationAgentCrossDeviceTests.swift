//
//  IntegrationAgentCrossDeviceTests.swift
//  ArgosTests
//
//  Agentes persistentes entre el Mac y el iPhone contra un servidor real con el `claude`
//  SIMULADO: uno creado «como lo haría el Mac» (store del panel Agente) se sigue y se
//  continúa «como lo haría el iPhone» (cliente `PersistentAgentSession` que lista y se
//  engancha), y al revés; y «Continuar en el servidor» de una conversación del panel
//  (mismo id con `--resume`, sin perder lo que se veía y sin dejar el claude del panel).
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Agentes persistentes: Mac ↔ iPhone")
@MainActor
struct AgentCrossDevice {

    private func store() -> AgentSessionStore {
        AgentSessionStore(registry: AgentPanelRegistry(suiteName: "argos-it-cross-\(UUID())"))
    }

    private func folder(_ box: RemoteBox, _ label: String) async throws -> String {
        let path = "\(box.root)/\(label)-\(UUID().uuidString.prefix(6).lowercased())"
        try await box.sh("mkdir -p \(box.q(path))")
        return path
    }

    /// Lo que haría el iPhone: listar los agentes del servidor y engancharse a uno.
    private func phoneSession(_ box: RemoteBox, id: String) async throws -> PersistentAgentSession {
        let listed = try await PersistentAgentSession.list(service: box.service)
        let info = try #require(listed.first { $0.id == id }, "El iPhone no ve el agente en el servidor")
        let session = PersistentAgentSession(service: box.service, info: info, hibernation: { noHibernation })
        session.attach()
        return session
    }

    nonisolated private static func cleanUp(_ box: RemoteBox, ids: [String]) async {
        for id in ids {
            _ = try? await box.sh(PersistentAgentScript.stop(id: id, delete: true, graceSeconds: 2))
        }
        await box.close()
    }

    @Test("Creado en el Mac (Mantener en el servidor), seguido y continuado desde el iPhone", .timeLimit(.minutes(2)))
    func macCreatesPhoneFollows() async throws {
        let box = try await RemoteBox.open("cross-mac")
        let workdir = try await folder(box, "mac")
        let store = store()
        let handle = SessionHandle(serverID: UUID(), sessionID: "web")
        let tabID = try await store.launchPersistent(
            for: handle, service: box.service, folder: workdir, title: "web", permissionMode: .default,
            oauthToken: nil, claudePath: box.fakeClaude, hibernation: noHibernation
        )
        let mac = try #require(store.slots(for: handle).first { $0.id == tabID }?.persistentTab?.session)
        let agentID = mac.id
        defer { IntegrationCleanup.later { await Self.cleanUp(box, ids: [agentID]) } }

        #expect(await mac.submit("hola desde el Mac", confirmedResume: false) == .sent)
        #expect(try await eventually(seconds: 15) { mac.assistantTexts.contains { $0.contains("hola desde el Mac") } })

        // El iPhone ve la conversación entera y la continúa.
        let phone = try await phoneSession(box, id: mac.id)
        #expect(try await eventually(seconds: 15) { phone.userTexts == ["hola desde el Mac"] && phone.assistantTexts.count == 1 })
        #expect(await phone.send("y ahora desde el iPhone") == .sent)
        // El Mac, que sigue enganchado, lo ve llegar.
        #expect(try await eventually(seconds: 15) {
            mac.userTexts.contains("y ahora desde el iPhone") && mac.assistantTexts.count == 2
        })

        // Cerrar la pestaña del Mac y «salir» (stopAll) no detiene el agente.
        store.closeTab(tabID, for: handle)
        await store.stopAll()
        #expect(try await box.sh("if \(PersistentAgentScript.aliveCheck(mac.id)); then echo vivo; fi").contains("vivo"))
        phone.detach()
    }

    @Test("Creado en el iPhone, listado y seguido en el panel del Mac", .timeLimit(.minutes(2)))
    func phoneCreatesMacFollows() async throws {
        let box = try await RemoteBox.open("cross-phone")
        let agent = try await box.launchAgent(title: "api")
        defer { IntegrationCleanup.later { await box.removeAgents([agent]); await box.close() } }
        let phone = try await box.session(for: agent)
        phone.attach()
        #expect(await phone.send("empieza el iPhone") == .sent)
        #expect(try await eventually(seconds: 15) { phone.assistantTexts.count == 1 })

        // El Mac lo encuentra en la carpeta del proyecto (sondeo) y lo abre en una pestaña.
        let store = store()
        let serverID = UUID()
        let handle = SessionHandle(serverID: serverID, sessionID: "api")
        await store.watch.refresh(serverID: serverID, service: box.service)
        let overview = try #require(store.watch.agents(serverID: serverID, folder: agent.workingDirectory + "/").first)
        #expect(overview.id == agent.id)
        #expect(overview.activity == .idle, "Terminó su turno: espera un mensaje")
        let tabID = store.openPersistent(overview.info, for: handle, service: box.service)
        let mac = try #require(store.slots(for: handle).first { $0.id == tabID }?.conversation)
        #expect(mac.lifecycle == .persistent)
        #expect(try await eventually(seconds: 15) { mac.state.items.count == 3 }, "Prompt, respuesta y fin del turno del iPhone")
        #expect(await mac.submit("sigue el Mac", confirmedResume: false) == .sent)
        #expect(try await eventually(seconds: 15) { phone.userTexts.contains("sigue el Mac") && phone.assistantTexts.count == 2 })
        store.closeAll(for: handle)
        phone.detach()
    }

    @Test("«Continuar en el servidor»: misma conversación con --resume, visible desde el iPhone", .timeLimit(.minutes(2)))
    func continueOnServer() async throws {
        let box = try await RemoteBox.open("cross-convert")
        let workdir = try await folder(box, "convert")
        let store = store()
        let handle = SessionHandle(serverID: UUID(), sessionID: "web")
        let sessionID = UUID().uuidString.lowercased()
        defer { IntegrationCleanup.later { await Self.cleanUp(box, ids: [sessionID]) } }
        let command = ClaudeAgentCommand.build(
            claudePath: box.fakeClaude, workingDirectory: workdir, sessionID: sessionID, permissionMode: .default
        )
        let tab = store.newTab(for: handle, service: box.service, command: command, workingDirectory: workdir,
                               oauthToken: nil, permissionMode: .default, sessionID: sessionID)
        tab.session.sendUserText("primero en el Mac")
        #expect(try await eventually(seconds: 15) { tab.session.state.status == .idle && tab.session.hasConversation })

        try await store.continueOnServer(tab.id, for: handle, service: box.service, oauthToken: nil,
                                         claudePath: box.fakeClaude, hibernation: noHibernation)
        let mac = try #require(store.slots(for: handle).first?.persistentTab?.session)
        #expect(mac.id == sessionID)
        #expect(mac.userTexts == ["primero en el Mac"], "Lo que se veía sigue ahí")
        // El claude del panel ya no corre; el persistente sí, reanudando la conversación.
        let inventory = try await box.service.serverAgentInventory()
        #expect(!inventory.agents.contains { agent in
            if case .panel = agent.kind { return agent.sessionID == sessionID }
            return false
        })
        let calls = try await box.read(workdir + "/.argos-fake-calls")
        #expect(calls.contains("--resume \(sessionID)") && calls.contains("--replay-user-messages"))

        #expect(await mac.submit("segundo, ya en el servidor", confirmedResume: false) == .sent)
        #expect(try await eventually(seconds: 15) { mac.assistantTexts.count == 2 })

        // El iPhone reconstruye la conversación entera desde el log.
        let phone = try await phoneSession(box, id: sessionID)
        #expect(try await eventually(seconds: 15) {
            phone.userTexts == ["primero en el Mac", "segundo, ya en el servidor"] && phone.assistantTexts.count == 2
        })
        // Convertirla otra vez no pisa el agente que ya existe.
        let again = store.newTab(for: handle, service: box.service, command: command, workingDirectory: workdir,
                                 oauthToken: nil, permissionMode: .default, sessionID: sessionID)
        again.session.sendUserText("otra vez")
        #expect(try await eventually(seconds: 15) { again.session.state.status == .idle })
        await #expect(throws: AgentConversionError.alreadyPersistent) {
            try await store.continueOnServer(again.id, for: handle, service: box.service, oauthToken: nil,
                                             claudePath: box.fakeClaude, hibernation: noHibernation)
        }
        #expect(try await box.sh("if \(PersistentAgentScript.aliveCheck(sessionID)); then echo vivo; fi").contains("vivo"))
        phone.detach()
        store.closeAll(for: handle)
    }
}

}
