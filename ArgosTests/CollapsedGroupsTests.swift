//
//  CollapsedGroupsTests.swift
//  ArgosTests
//
//  Grupos de sesiones colapsables: el estado es por (servidor, grupo) y persiste en
//  UserDefaults entre reinicios.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Grupos de sesiones colapsables")
struct CollapsedGroupsTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "argos.tests.collapsed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Por defecto ningún grupo está colapsado")
    func defaultExpanded() {
        let store = CollapsedSessionGroups(defaults: makeDefaults())
        #expect(!store.isCollapsed(serverID: UUID(), group: "ia-portafolio"))
    }

    @Test("Alternar colapsa y vuelve a expandir")
    func toggles() {
        let store = CollapsedSessionGroups(defaults: makeDefaults())
        let server = UUID()
        store.toggle(serverID: server, group: "ia-portafolio")
        #expect(store.isCollapsed(serverID: server, group: "ia-portafolio"))
        store.toggle(serverID: server, group: "ia-portafolio")
        #expect(!store.isCollapsed(serverID: server, group: "ia-portafolio"))
    }

    @Test("El estado es independiente por servidor y por grupo")
    func scopedPerServerAndGroup() {
        let store = CollapsedSessionGroups(defaults: makeDefaults())
        let a = UUID(), b = UUID()
        store.toggle(serverID: a, group: "web")
        #expect(store.isCollapsed(serverID: a, group: "web"))
        #expect(!store.isCollapsed(serverID: b, group: "web"))
        #expect(!store.isCollapsed(serverID: a, group: "api"))
    }

    @Test("Persiste entre instancias (reinicio de la app)")
    func persists() {
        let defaults = makeDefaults()
        let server = UUID()
        CollapsedSessionGroups(defaults: defaults).toggle(serverID: server, group: "inducascos")
        #expect(CollapsedSessionGroups(defaults: defaults).isCollapsed(serverID: server, group: "inducascos"))
    }

    @Test("El aviso de un grupo colapsado es el estado de Claude más urgente")
    func groupClaudeActivity() {
        let snapshot = ClaudeActivitySnapshot(listPanesOutput: "-|working|%1|1|g/a\n-|waiting|%2|1|g/b\n-|done|%3|1|g/c")
        let sessions = ["g/a", "g/b", "g/c"].map {
            TmuxSession(name: $0, windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))
        }
        #expect(snapshot.activity(forSessions: sessions.map(\.name)) == .waiting)
        #expect(snapshot.activity(forSessions: ["g/a"]) == .working)
        #expect(snapshot.activity(forSessions: ["otra"]) == nil)
    }
}
