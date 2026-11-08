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
        let w = try #require(TmuxWindow(line: "2|1|3|blue|vim|editor"))
        #expect(w.index == 2)
        #expect(w.name == "editor")
        #expect(w.currentCommand == "vim")
        #expect(w.isActive)
        #expect(w.paneCount == 3)
        #expect(w.color == .blue)
    }

    @Test("active = 0 => no activa")
    func notActive() throws {
        let w = try #require(TmuxWindow(line: "0|0|1||bash|bash"))
        #expect(!w.isActive)
        #expect(w.index == 0)
    }

    @Test("Sin color (opción vacía) => color nil")
    func noColor() throws {
        let w = try #require(TmuxWindow(line: "1|1|1||zsh|zsh"))
        #expect(w.color == nil)
    }

    @Test("Color desconocido se ignora (color nil), no invalida la ventana")
    func unknownColor() throws {
        let w = try #require(TmuxWindow(line: "1|1|1|chartreuse|zsh|zsh"))
        #expect(w.color == nil)
        #expect(w.name == "zsh")
    }

    @Test("Nombre con espacios se conserva")
    func nameWithSpaces() throws {
        let w = try #require(TmuxWindow(line: "1|1|1||zsh|mi ventana"))
        #expect(w.name == "mi ventana")
    }

    @Test("Nombre con '|' se conserva (el nombre va al final)")
    func nameWithPipe() throws {
        let w = try #require(TmuxWindow(line: "1|1|1|red|zsh|a|b"))
        #expect(w.name == "a|b")
        #expect(w.color == .red)
    }

    @Test("Líneas inválidas devuelven nil", arguments: [
        "", "  ", "x|1|1|||bash", "1|1|1|||", "1|1|1||bash", "1|1|x|||bash", "1|x|1|||bash",
    ])
    func invalidReturnsNil(line: String) {
        #expect(TmuxWindow(line: line) == nil)
    }

    @Test("Comando vacío (tmux no lo informó) => currentCommand nil")
    func emptyCommand() throws {
        let w = try #require(TmuxWindow(line: "1|1|1|||zsh"))
        #expect(w.currentCommand == nil)
        #expect(w.name == "zsh")
    }
}
