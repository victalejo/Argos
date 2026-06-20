//
//  TerminalPoolEvictionTests.swift
//  ArgosTests
//
//  Lógica de desalojo LRU del pool de terminales: nunca desalojar el terminal recién
//  solicitado, y desalojar los menos usados hasta respetar el tope.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Pool de terminales (LRU)")
struct TerminalPoolEvictionTests {

    private func handle(_ name: String) -> SessionHandle {
        SessionHandle(serverID: UUID(), sessionID: name)
    }

    @Test("Por debajo del tope no desaloja nada")
    func underCap() {
        let a = handle("a"), b = handle("b"), c = handle("c")
        let victims = TerminalSessionStore.evictionVictims(
            lruOrder: [a, b, c], keep: c, maxLive: 8
        )
        #expect(victims.isEmpty)
    }

    @Test("Justo en el tope no desaloja")
    func atCap() {
        let a = handle("a"), b = handle("b")
        let victims = TerminalSessionStore.evictionVictims(
            lruOrder: [a, b], keep: b, maxLive: 2
        )
        #expect(victims.isEmpty)
    }

    @Test("Uno por encima desaloja el menos reciente (frente de la lista)")
    func oneOverEvictsLeastRecent() {
        let a = handle("a"), b = handle("b"), c = handle("c")
        let victims = TerminalSessionStore.evictionVictims(
            lruOrder: [a, b, c], keep: c, maxLive: 2
        )
        #expect(victims == [a])
    }

    @Test("Nunca desaloja el recién solicitado aunque esté al frente")
    func neverEvictsKept() {
        let a = handle("a"), b = handle("b"), c = handle("c")
        let victims = TerminalSessionStore.evictionVictims(
            lruOrder: [a, b, c], keep: a, maxLive: 2
        )
        #expect(victims == [b])
        #expect(!victims.contains(a))
    }

    @Test("Varios por encima desaloja tantos como el exceso, de más antiguo a más nuevo")
    func multipleOver() {
        let a = handle("a"), b = handle("b"), c = handle("c"), d = handle("d"), e = handle("e")
        let victims = TerminalSessionStore.evictionVictims(
            lruOrder: [a, b, c, d, e], keep: e, maxLive: 2
        )
        #expect(victims == [a, b, c])
    }
}
