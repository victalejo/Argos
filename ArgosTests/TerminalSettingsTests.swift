//
//  TerminalSettingsTests.swift
//  ArgosTests
//
//  Acotado del tamaño de fuente del terminal (zoom ⌘+/⌘-/⌘0).
//

import Testing
@testable import Argos

@MainActor
@Suite("Tamaño de fuente del terminal")
struct TerminalSettingsTests {

    @Test("Por debajo del mínimo se acota al mínimo")
    func clampsBelowMin() {
        #expect(TerminalSettings.clampFontSize(2) == TerminalSettings.minFontSize)
    }

    @Test("Por encima del máximo se acota al máximo")
    func clampsAboveMax() {
        #expect(TerminalSettings.clampFontSize(999) == TerminalSettings.maxFontSize)
    }

    @Test("Dentro del rango se conserva")
    func keepsWithinRange() {
        #expect(TerminalSettings.clampFontSize(14) == 14)
    }

    @Test("El tamaño por defecto está dentro del rango")
    func defaultIsValid() {
        #expect(TerminalSettings.defaultFontSize >= TerminalSettings.minFontSize)
        #expect(TerminalSettings.defaultFontSize <= TerminalSettings.maxFontSize)
    }
}
