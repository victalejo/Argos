//
//  ClaudeLoginOutputTests.swift
//  ArgosTests
//
//  Parser de la salida de `claude auth login` (fixture: salida REAL capturada en un
//  servidor Ubuntu con el CLI de 2026, con el hipervínculo OSC 8 incluido).
//

import Foundation
import Testing
@testable import Argos

@Suite("Login de Claude: salida del CLI")
struct ClaudeLoginOutputTests {

    static let url = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&response_type=code&state=abc"

    static let realOutput = "Opening browser to sign in\u{2026}\r\n"
        + "If the browser didn't open, visit: \u{1B}]8;;\(url)\u{07}\(url)\u{1B}]8;;\u{07}\r\n"
        + "Paste code here if prompted > "

    @Test("Detecta el enlace de autorización y que pide el código")
    func parsesRealOutput() {
        let output = ClaudeLoginOutput.parse(Self.realOutput)
        #expect(output.authorizationURL?.absoluteString == Self.url)
        #expect(output.isAwaitingCode)
    }

    @Test("Salida parcial: aún sin enlace ni petición de código")
    func partialOutput() {
        let output = ClaudeLoginOutput.parse("Opening browser to sign in\u{2026}\r\n")
        #expect(output.authorizationURL == nil)
        #expect(!output.isAwaitingCode)
    }

    @Test("Quita OSC, CSI y retornos de carro")
    func stripsEscapes() {
        let raw = "\u{1B}[1mHola\u{1B}[0m\r\n\u{1B}]0;titulo\u{07}mundo \u{1B}]8;;https://x\u{1B}\\enlace"
        #expect(ClaudeLoginOutput.stripEscapes(raw) == "Hola\nmundo enlace")
    }

    @Test("Ignora enlaces OAuth de dominios que no son de Anthropic")
    func rejectsUntrustedHosts() {
        let evil = "visit: https://claude.com.evil.io/oauth/authorize?x=1 or https://evil.com/oauth"
        #expect(ClaudeLoginOutput.parse(evil).authorizationURL == nil)
        let sub = "visit: https://login.claude.ai/oauth/authorize?x=1"
        #expect(ClaudeLoginOutput.parse(sub).authorizationURL?.host == "login.claude.ai")
    }
}
