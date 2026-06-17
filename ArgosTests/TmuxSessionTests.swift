//
//  TmuxSessionTests.swift
//  ArgosTests
//
//  Parser de la salida de `tmux list-sessions -F '#{session_name}|...'`.
//

import Foundation
import Testing
@testable import Argos

@Suite("Parser TmuxSession(line:)")
struct TmuxSessionTests {

    @Test("Línea bien formada parsea todos los campos")
    func valid() throws {
        let session = try #require(TmuxSession(line: "main|3|1|1700000000"))
        #expect(session.name == "main")
        #expect(session.windowCount == 3)
        #expect(session.isAttached == true)
        #expect(session.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("attached = 0 => no adjunta")
    func notAttached() throws {
        let session = try #require(TmuxSession(line: "logs|1|0|1700000000"))
        #expect(session.isAttached == false)
    }

    @Test("Líneas inválidas devuelven nil", arguments: [
        "",                       // vacía
        "   ",                    // solo espacios
        "main|3|1",               // 3 campos (faltan)
        "main|3|1|1700|extra",    // 5 campos (sobran)
        "main|x|1|1700000000",    // windowCount no numérico
        "main|3|y|1700000000",    // attached no numérico
        "main|3|1|notanepoch",    // epoch no numérico
        "|3|1|1700000000"         // nombre vacío
    ])
    func invalid(line: String) {
        #expect(TmuxSession(line: line) == nil)
    }

    @Test("Espacios alrededor de la línea se toleran")
    func trimsLine() throws {
        let session = try #require(TmuxSession(line: "  main|2|0|1700000000  \n"))
        #expect(session.name == "main")
        #expect(session.windowCount == 2)
    }
}
