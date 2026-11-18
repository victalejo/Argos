//
//  AttentionTests.swift
//  ArgosTests
//
//  Bandeja de atención: qué entra, en qué orden, a dónde lleva y cuándo deja de estar
//  pendiente; el recorrido «siguiente» y el recuento de la insignia del Dock.
//

import Foundation
import Testing
@testable import Argos

@Suite("Bandeja de atención")
struct AttentionTests {

    private let server = UUID()
    private let other = UUID()

    private func snapshot(_ lines: String) -> ClaudeActivitySnapshot {
        ClaudeActivitySnapshot(listPanesOutput: lines)
    }

    private func project(_ name: String, path: String) -> Project {
        Project(name: name, path: path)
    }

    private func ciResult(_ state: GitHubCheckState, root: String = "/srv/web") -> CIResult {
        CIResult(
            watch: CIWatch(root: root, name: "web", sha: "abcdef123", since: Date(timeIntervalSince1970: 0)),
            state: state, failed: state == .failure ? ["CI"] : [], url: nil
        )
    }

    @Test("Claude esperando sale del estado actual, con su ventana y el nombre del proyecto")
    func waitingFromSnapshot() {
        let web = project("web", path: "/srv/web")
        let items = AttentionList.build(
            inbox: AttentionInbox(),
            servers: [.init(serverID: server, claude: snapshot("0|waiting|%1|2|\(web.sessionName)"), projects: [web])]
        )
        #expect(items.count == 1)
        #expect(items.first?.kind == .claudeWaiting)
        #expect(items.first?.title == "web")
        #expect(items.first?.destination == .terminal(SessionHandle(serverID: server, sessionID: web.sessionName), window: 2))
        #expect(items.first?.needsResponse == true)
    }

    @Test("«Terminó» queda pendiente hasta mirarlo o hasta que el panel vuelve a trabajar")
    func doneUntilSeen() {
        var inbox = AttentionInbox()
        let done = snapshot("-|done|%1|0|api")
        inbox.absorb(serverID: server, transitions: [ClaudeTransition(session: "api", window: 0, activity: .done)],
                     snapshot: done, ciResults: [])
        #expect(AttentionList.build(inbox: inbox, servers: []).map(\.kind) == [.claudeDone])

        inbox.markSeen(serverID: server, session: "api")
        #expect(inbox.unseenDone.isEmpty)

        inbox.absorb(serverID: server, transitions: [ClaudeTransition(session: "api", window: 0, activity: .done)],
                     snapshot: done, ciResults: [])
        inbox.absorb(serverID: server, transitions: [], snapshot: snapshot("2|working|%1|0|api"), ciResults: [])
        #expect(inbox.unseenDone.isEmpty)
    }

    @Test("Un CI fallido lleva a «Cambios» y sale con un resultado posterior que pasa")
    func ciFailure() {
        var inbox = AttentionInbox()
        let web = project("web", path: "/srv/web")
        inbox.absorb(serverID: server, transitions: [], snapshot: .empty, ciResults: [ciResult(.failure)])
        let items = AttentionList.build(inbox: inbox, servers: [.init(serverID: server, claude: .empty, projects: [web])])
        #expect(items.first?.kind == .ciFailed)
        #expect(items.first?.destination == .project(SessionHandle(serverID: server, sessionID: web.sessionName), mode: .changes))
        #expect(items.first?.needsResponse == false)

        inbox.absorb(serverID: server, transitions: [], snapshot: .empty, ciResults: [ciResult(.success)])
        #expect(inbox.failedCI.isEmpty)
    }

    @Test("Orden por urgencia entre todos los servidores")
    func orderedByUrgency() {
        var inbox = AttentionInbox()
        inbox.absorb(serverID: other, transitions: [ClaudeTransition(session: "z", window: 0, activity: .done)],
                     snapshot: snapshot("-|done|%9|0|z"), ciResults: [ciResult(.failure)])
        let handle = SessionHandle(serverID: other, sessionID: "z")
        let items = AttentionList.build(
            inbox: inbox,
            servers: [
                .init(serverID: server, claude: snapshot("0|waiting|%1|0|a"), projects: []),
                .init(serverID: other, claude: snapshot("-|done|%9|0|z"), projects: []),
            ],
            agents: [.init(handle: handle, tabID: UUID(), conversation: "Refactor", toolName: "Bash")],
            ports: [.init(serverID: server, request: PortForwardRequest(port: 3000, note: "", ageSeconds: 1))],
            syncs: [.init(serverID: other, projectID: UUID(), projectName: "z", failed: true, message: "Sin espacio")]
        )
        #expect(items.map(\.kind) == [.claudeWaiting, .agentPermission, .ciFailed, .portRequest, .syncFailed, .claudeDone])
        #expect(AttentionList.responseCount(items) == 3)
    }

    @Test("«Siguiente» recorre la bandeja y vuelve al principio")
    func nextCycles() {
        let items = AttentionList.build(
            inbox: AttentionInbox(),
            servers: [.init(serverID: server, claude: snapshot("0|waiting|%1|0|a\n0|waiting|%2|1|b"), projects: [])]
        )
        let first = AttentionList.next(after: nil, in: items)
        let second = AttentionList.next(after: first?.id, in: items)
        #expect(first?.title == "a")
        #expect(second?.title == "b")
        #expect(AttentionList.next(after: second?.id, in: items)?.title == "a")
        #expect(AttentionList.next(after: "desconocido", in: items)?.title == "a")
        #expect(AttentionList.next(after: nil, in: []) == nil)
    }

    @Test("Elegir o borrar el servidor saca sus elementos")
    func resolveAndForget() {
        var inbox = AttentionInbox()
        inbox.absorb(serverID: server, transitions: [ClaudeTransition(session: "a", window: 0, activity: .done)],
                     snapshot: snapshot("-|done|%1|0|a"), ciResults: [ciResult(.failure)])
        let ci = AttentionList.build(inbox: inbox, servers: []).first { $0.kind == .ciFailed }
        inbox.resolve(id: ci?.id ?? "")
        #expect(inbox.failedCI.isEmpty)
        inbox.forget(serverID: server)
        #expect(inbox.unseenDone.isEmpty)
    }

    @Test("Cada fila se lee completa con VoiceOver (tipo, qué, dónde)")
    func accessibility() {
        let items = AttentionList.build(
            inbox: AttentionInbox(),
            servers: [.init(serverID: server, claude: snapshot("0|waiting|%1|0|web"), projects: [])]
        )
        let label = items.first?.accessibilityLabel(serverName: "dev") ?? ""
        #expect(label.contains("Claude espera tu respuesta"))
        #expect(label.contains("web"))
        #expect(label.contains("dev"))
    }
}
