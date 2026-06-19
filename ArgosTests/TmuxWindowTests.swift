//
//  TmuxWindowTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("Parser TmuxWindow(line:)")
struct TmuxWindowTests {

    @Test("Línea bien formada parsea todos los campos")
    func parsesAllFields() throws {
        let w = try #require(TmuxWindow(line: "2|vim|1|3"))
        #expect(w.index == 2)
        #expect(w.name == "vim")
        #expect(w.isActive)
        #expect(w.paneCount == 3)
    }

    @Test("active = 0 => no activa")
    func notActive() throws {
        let w = try #require(TmuxWindow(line: "0|bash|0|1"))
        #expect(!w.isActive)
        #expect(w.index == 0)
    }

    @Test("Nombre con espacios se conserva")
    func nameWithSpaces() throws {
        let w = try #require(TmuxWindow(line: "1|mi ventana|1|1"))
        #expect(w.name == "mi ventana")
    }

    @Test("Líneas inválidas devuelven nil", arguments: [
        "", "  ", "x|bash|1|1", "1||1|1", "1|bash|1", "1|bash|1|x", "1|bash|x|1",
    ])
    func invalidReturnsNil(line: String) {
        #expect(TmuxWindow(line: line) == nil)
    }
}
