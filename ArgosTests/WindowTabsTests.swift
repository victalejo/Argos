//
//  WindowTabsTests.swift
//  ArgosTests
//
//  Lógica pura de las pestañas: cierre con ⌘W (directo, con confirmación o bloqueado),
//  atajos ⌘1…⌘9 y anterior/siguiente, agente y título de cada pestaña.
//

import Testing
@testable import Argos

@Suite("Pestañas de ventanas tmux")
struct WindowTabsTests {

    private func window(
        _ index: Int,
        name: String = "zsh",
        active: Bool = false,
        panes: Int = 1,
        command: String? = "zsh"
    ) -> TmuxWindow {
        TmuxWindow(index: index, name: name, isActive: active, paneCount: panes, currentCommand: command)
    }

    // MARK: - Cierre

    @Test("La última ventana no se cierra (mataría la sesión)")
    func lastWindowBlocked() {
        #expect(WindowTabs.closeDecision(for: window(0), totalWindows: 1) == .blocked)
    }

    @Test("Un shell ocioso se cierra sin preguntar", arguments: ["zsh", "bash", "-zsh", "fish", "sh"])
    func idleShellImmediate(command: String) {
        #expect(WindowTabs.closeDecision(for: window(1, command: command), totalWindows: 2) == .immediate)
    }

    @Test("Con algo corriendo se pide confirmación", arguments: ["claude", "vim", "node"])
    func runningProcessConfirms(command: String) {
        #expect(WindowTabs.closeDecision(for: window(1, command: command), totalWindows: 2) == .confirm)
    }

    @Test("Varios paneles o comando desconocido => confirmación")
    func multiplePanesOrUnknownConfirm() {
        #expect(WindowTabs.closeDecision(for: window(1, panes: 2), totalWindows: 3) == .confirm)
        #expect(WindowTabs.closeDecision(for: window(1, command: nil), totalWindows: 3) == .confirm)
    }

    // MARK: - Atajos

    @Test("⌘N salta por posición, no por índice de tmux")
    func shortcutByPosition() {
        let windows = [window(1), window(3), window(7)]
        #expect(WindowTabs.window(atShortcut: 1, in: windows)?.index == 1)
        #expect(WindowTabs.window(atShortcut: 2, in: windows)?.index == 3)
        #expect(WindowTabs.window(atShortcut: 4, in: windows) == nil)
    }

    @Test("⌘9 es siempre la última pestaña")
    func nineIsLast() {
        let windows = [window(0), window(1), window(2)]
        #expect(WindowTabs.window(atShortcut: 9, in: windows)?.index == 2)
    }

    @Test("Atajos fuera de rango o sin ventanas => nada", arguments: [0, 10, -1])
    func outOfRange(number: Int) {
        #expect(WindowTabs.position(forShortcut: number, count: 3) == nil)
        #expect(WindowTabs.position(forShortcut: 1, count: 0) == nil)
    }

    @Test("Anterior/siguiente da la vuelta en los extremos")
    func adjacentWraps() {
        let windows = [window(0), window(1), window(2, active: true)]
        #expect(WindowTabs.adjacent(to: windows, offset: 1)?.index == 0)
        #expect(WindowTabs.adjacent(to: windows, offset: -1)?.index == 1)
        #expect(WindowTabs.adjacentPosition(current: 0, offset: -1, count: 3) == 2)
    }

    @Test("Con una sola pestaña no hay anterior/siguiente")
    func adjacentSingle() {
        #expect(WindowTabs.adjacent(to: [window(0, active: true)], offset: 1) == nil)
    }

    // MARK: - Agente y título

    @Test("Los hooks de Claude marcan la ventana como Claude Code")
    func claudeFromHooks() {
        #expect(WindowTabs.agent(for: window(1, command: "node"), claudeReported: true) == .claude)
        #expect(WindowTabs.agent(for: window(1, command: "node"), claudeReported: false) == nil)
    }

    @Test("Título: nombre del agente, nombre propio o nada si es el shell")
    func titles() {
        #expect(WindowTabs.title(for: window(1), agent: .grok) == "Grok")
        #expect(WindowTabs.title(for: window(1, name: "servidor"), agent: nil) == "servidor")
        #expect(WindowTabs.title(for: window(1, name: "zsh"), agent: nil) == nil)
    }

    @Test("Solo los agentes repetidos llevan número")
    func repeatedAgents() {
        let windows = [
            window(0, command: "claude"), window(1, command: "claude"),
            window(2, command: "codex"), window(3, command: "node"),
        ]
        #expect(WindowTabs.repeatedAgents(in: windows, claudeReported: []) == [.claude])
        #expect(WindowTabs.repeatedAgents(in: windows, claudeReported: [3]) == [.claude])
        #expect(WindowTabs.repeatedAgents(in: [window(0, command: "grok")], claudeReported: []).isEmpty)
    }
}
