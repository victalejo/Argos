//
//  TerminalKeysTests.swift
//  ArgosTests
//
//  Secuencias que envía cada tecla de la barra del terminal de iPhone/iPad (paridad con
//  `TerminalKeyEncoderTest.kt` de Android, más Mayús+Tab) y modificadores pegajosos.
//

import Foundation
import Testing
@testable import Argos

@Suite("Barra de teclas del terminal")
struct TerminalKeysTests {

    private func send(_ key: ExtraKey, ctrl: Bool = false, alt: Bool = false, app: Bool = false) -> String {
        String(decoding: TerminalKeyEncoder.bytes(for: key, ctrl: ctrl, alt: alt, applicationCursor: app), as: UTF8.self)
    }

    @Test("Teclas simples")
    func plainKeys() {
        #expect(send(.esc) == "\u{1B}")
        #expect(send(.tab) == "\t")
        #expect(send(.shiftTab) == "\u{1B}[Z")
        #expect(send(.tmuxPrefix) == "\u{02}")
        #expect(send(.pipe) == "|")
        #expect(send(.tilde) == "~")
        #expect(send(.slash) == "/")
        #expect(send(.dash) == "-")
    }

    @Test("Flechas, Inicio y Fin en modo normal y de aplicación")
    func cursorKeys() {
        #expect(send(.up) == "\u{1B}[A")
        #expect(send(.down) == "\u{1B}[B")
        #expect(send(.right) == "\u{1B}[C")
        #expect(send(.left) == "\u{1B}[D")
        #expect(send(.home) == "\u{1B}[H")
        #expect(send(.end) == "\u{1B}[F")
        #expect(send(.up, app: true) == "\u{1B}OA")
        #expect(send(.home, app: true) == "\u{1B}OH")
    }

    @Test("Modificadores xterm en flechas y páginas")
    func modifiedCursorKeys() {
        #expect(send(.left, ctrl: true) == "\u{1B}[1;5D")
        #expect(send(.right, alt: true) == "\u{1B}[1;3C")
        #expect(send(.up, ctrl: true, alt: true, app: true) == "\u{1B}[1;7A")
        #expect(send(.pageUp) == "\u{1B}[5~")
        #expect(send(.pageDown) == "\u{1B}[6~")
        #expect(send(.pageUp, ctrl: true) == "\u{1B}[5;5~")
    }

    @Test("Alt antepone ESC; Ctrl convierte en código de control")
    func altAndCtrl() {
        #expect(send(.esc, alt: true) == "\u{1B}\u{1B}")
        #expect(send(.shiftTab, alt: true) == "\u{1B}\u{1B}[Z")
        #expect(send(.slash, ctrl: true) == "\u{1F}")
        #expect(send(.dash, ctrl: true, alt: true) == "\u{1B}\u{1F}")
        #expect(TerminalKeyEncoder.character("c", ctrl: true, alt: false) == [0x03])
        #expect(TerminalKeyEncoder.character("ñ", ctrl: true, alt: false) == Array("ñ".utf8))
    }

    @Test("Ctrl, Alt y ocultar teclado no envían nada")
    func silentKeys() {
        #expect(send(.ctrl).isEmpty)
        #expect(send(.alt).isEmpty)
        #expect(send(.hideKeyboard).isEmpty)
    }

    @Test("Ctrl pegajoso: un toque para la próxima tecla, dos lo fijan, tres lo apagan")
    func stickyLatch() {
        var mods = StickyModifiers()
        mods = TerminalKeyEncoder.encode(.ctrl, modifiers: mods, applicationCursor: false).modifiers
        #expect(mods.ctrl == .once)
        let first = TerminalKeyEncoder.encode(.left, modifiers: mods, applicationCursor: false)
        #expect(first.bytes == Array("\u{1B}[1;5D".utf8))
        #expect(first.modifiers.ctrl == .off)

        mods = StickyModifiers().tapped(.ctrl).tapped(.ctrl)
        #expect(mods.ctrl == .locked)
        let locked = TerminalKeyEncoder.encode(.left, modifiers: mods, applicationCursor: false)
        #expect(locked.modifiers.ctrl == .locked)
        #expect(mods.tapped(.ctrl).ctrl == .off)
    }

    @Test("Ocultar teclado conserva los modificadores")
    func hideKeepsModifiers() {
        let mods = StickyModifiers().tapped(.alt)
        #expect(TerminalKeyEncoder.encode(.hideKeyboard, modifiers: mods, applicationCursor: false).modifiers == mods)
    }

    @Test("La barra contiene todas las teclas una vez")
    func barOrderComplete() {
        #expect(Set(ExtraKey.barOrder) == Set(ExtraKey.allCases))
        #expect(ExtraKey.barOrder.count == ExtraKey.allCases.count)
        #expect(ExtraKey.allCases.allSatisfy { $0.label != nil || $0.symbolName != nil })
    }

    @Test("Pellizco: escala, redondeo a medio punto y límites")
    func pinchFontSize() {
        #expect(TerminalFontSizing.pinched(from: 12, scale: 1.5) == 18)
        #expect(TerminalFontSizing.pinched(from: 12, scale: 1.02) == 12)
        #expect(TerminalFontSizing.pinched(from: 12, scale: 1.1) == 13)
        #expect(TerminalFontSizing.pinched(from: 12, scale: 10) == 24)
        #expect(TerminalFontSizing.pinched(from: 12, scale: 0.1) == 8)
        #expect(TerminalFontSizing.pinched(from: 12, scale: .nan) == 12)
    }
}
