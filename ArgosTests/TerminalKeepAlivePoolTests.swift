//
//  TerminalKeepAlivePoolTests.swift
//  ArgosTests
//
//  Terminales aparcados del iPhone/iPad: siguen vivos un rato al cambiar de pestaña y
//  se cierran al caducar, al superar el tope o al pasar a segundo plano.
//

import Foundation
import Testing
@testable import Argos

@Suite("Terminales aparcados")
struct TerminalKeepAlivePoolTests {
    private let start = ContinuousClock.now

    @Test("Aparcar y volver conserva el terminal")
    func parkAndReturn() {
        var pool = TerminalKeepAlivePool<String>(grace: .seconds(60), maxLive: 4)
        pool = pool.showing("a").parking("a", at: start)
        #expect(pool.parked.keys.contains("a"))
        #expect(pool.evictions(at: start + .seconds(30)).isEmpty)
        pool = pool.showing("a")
        #expect(pool.visible == ["a"])
        #expect(pool.parked.isEmpty)
        #expect(pool.evictions(at: start + .seconds(600)).isEmpty)
    }

    @Test("Un aparcado caduca pasado el plazo")
    func expires() {
        let pool = TerminalKeepAlivePool<String>(grace: .seconds(60), maxLive: 4)
            .showing("a").parking("a", at: start)
        #expect(pool.evictions(at: start + .seconds(60)) == ["a"])
        #expect(pool.nextExpiry == start + .seconds(60))
    }

    @Test("Por encima del tope se cierran los aparcados más antiguos, nunca los visibles")
    func overflow() {
        var pool = TerminalKeepAlivePool<String>(grace: .seconds(600), maxLive: 2)
        pool = pool.showing("a").parking("a", at: start)
        pool = pool.showing("b").parking("b", at: start + .seconds(1))
        pool = pool.showing("c")
        #expect(pool.evictions(at: start + .seconds(2)) == ["a"])

        let onlyVisible = TerminalKeepAlivePool<String>(grace: .seconds(600), maxLive: 1)
            .showing("x").showing("y")
        #expect(onlyVisible.evictions(at: start).isEmpty)
    }

    @Test("Aparcar algo desconocido no hace nada")
    func parkUnknown() {
        let pool = TerminalKeepAlivePool<String>().parking("z", at: start)
        #expect(pool.live.isEmpty)
    }

    @Test("Segundo plano: los aparcados se cierran, los visibles quedan")
    func dropParked() {
        let pool = TerminalKeepAlivePool<String>()
            .showing("a").showing("b").parking("b", at: start)
        let (after, dropped) = pool.droppingParked()
        #expect(dropped == ["b"])
        #expect(after.live == ["a"])
    }

    @Test("Quitar un terminal lo olvida")
    func remove() {
        let pool = TerminalKeepAlivePool<String>().showing("a").removing("a")
        #expect(pool.live.isEmpty)
    }
}
