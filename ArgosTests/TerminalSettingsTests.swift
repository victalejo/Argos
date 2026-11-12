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

@MainActor
@Suite("Tope de terminales vivos")
struct LiveTerminalLimitTests {

    @Test("Por debajo del mínimo se acota al mínimo")
    func clampsBelowMin() {
        #expect(TerminalSettings.clampLiveTerminalLimit(0) == TerminalSettings.minLiveTerminals)
    }

    @Test("Por encima del máximo se acota al máximo")
    func clampsAboveMax() {
        #expect(TerminalSettings.clampLiveTerminalLimit(10_000) == TerminalSettings.maxLiveTerminals)
    }

    @Test("Dentro del rango se conserva")
    func keepsWithinRange() {
        #expect(TerminalSettings.clampLiveTerminalLimit(12) == 12)
    }

    @Test("El valor por defecto está dentro del rango")
    func defaultIsValid() {
        let value = TerminalSettings.defaultLiveTerminals
        #expect(TerminalSettings.clampLiveTerminalLimit(value) == value)
    }

    @Test("Sin valor guardado (0 de UserDefaults) se usa el valor por defecto")
    func storedZeroMeansDefault() {
        #expect(TerminalSettings.liveTerminalLimit(fromStored: 0) == TerminalSettings.defaultLiveTerminals)
        #expect(TerminalSettings.liveTerminalLimit(fromStored: 10) == 10)
        #expect(TerminalSettings.liveTerminalLimit(fromStored: 500) == TerminalSettings.maxLiveTerminals)
    }
}
