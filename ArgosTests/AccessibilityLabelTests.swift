//
//  AccessibilityLabelTests.swift
//  ArgosTests
//
//  Fija el formato de las etiquetas de accesibilidad derivadas de lógica pura.
//

import Testing
@testable import Argos

@Suite("Etiquetas de accesibilidad")
struct AccessibilityLabelTests {

    @Test("Ventana activa con varios paneles incluye estado y nº de paneles")
    func activeWindowWithPanes() {
        let w = TmuxWindow(index: 2, name: "logs", isActive: true, paneCount: 3)
        #expect(WindowBar.accessibilityLabel(for: w) == "Ventana 2: logs, activa, 3 paneles")
    }

    @Test("Ventana inactiva de un solo panel solo lleva índice y nombre")
    func inactiveSinglePaneWindow() {
        let w = TmuxWindow(index: 1, name: "main", isActive: false, paneCount: 1)
        #expect(WindowBar.accessibilityLabel(for: w) == "Ventana 1: main")
    }

    @Test("Ventana activa de un panel marca 'activa' pero no paneles")
    func activeSinglePane() {
        let w = TmuxWindow(index: 0, name: "edit", isActive: true, paneCount: 1)
        #expect(WindowBar.accessibilityLabel(for: w) == "Ventana 0: edit, activa")
    }
}
