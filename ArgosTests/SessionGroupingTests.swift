//
//  SessionGroupingTests.swift
//  ArgosTests
//

import Foundation
import Testing
@testable import Argos

@Suite("Agrupamiento de sesiones por prefijo")
struct SessionGroupingTests {

    private func session(_ name: String) -> TmuxSession {
        TmuxSession(name: name, windowCount: 1, isAttached: false, createdAt: .init(timeIntervalSince1970: 0))
    }

    @Test("split separa por el primer '/'")
    func splitBasic() {
        let r = SessionGrouping.split("magic-agents/backend")
        #expect(r.group == "magic-agents")
        #expect(r.short == "backend")
    }

    @Test("Sin '/' va al grupo General con el nombre completo")
    func splitUngrouped() {
        let r = SessionGrouping.split("main")
        #expect(r.group == "General")
        #expect(r.short == "main")
    }

    @Test("Prefijo vacío '/foo' => General, nombre completo")
    func splitEmptyPrefix() {
        let r = SessionGrouping.split("/foo")
        #expect(r.group == "General")
        #expect(r.short == "/foo")
    }

    @Test("Sufijo vacío 'foo/' => grupo foo, nombre completo (no queda sin etiqueta)")
    func splitEmptySuffix() {
        let r = SessionGrouping.split("foo/")
        #expect(r.group == "foo")
        #expect(r.short == "foo/")
    }

    @Test("groups: 'General' SIEMPRE va al final")
    func generalLast() {
        let groups = SessionGrouping.groups(from: [
            session("zeta/a"),
            session("solo"),          // -> General
            session("alpha/b")
        ])
        #expect(groups.map(\.name) == ["alpha", "zeta", "General"])
    }

    @Test("groups: orden interno por nombre corto, case-insensitive")
    func internalOrder() {
        let groups = SessionGrouping.groups(from: [
            session("g/Charlie"),
            session("g/alpha"),
            session("g/Bravo")
        ])
        let g = try! #require(groups.first { $0.name == "g" })
        #expect(g.sessions.map(\.name) == ["g/alpha", "g/Bravo", "g/Charlie"])
    }

    @Test("Lista vacía produce cero grupos")
    func emptyInput() {
        #expect(SessionGrouping.groups(from: []).isEmpty)
    }
}
