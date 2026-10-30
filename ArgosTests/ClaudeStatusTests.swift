//
//  ClaudeStatusTests.swift
//  ArgosTests
//
//  Indicador de estado de Claude Code: parseo de `list-panes`, agregación por
//  sesión/ventana, transiciones notificables y fusión de hooks en settings.json.
//

import Foundation
import Testing
@testable import Argos

@Suite("Estado de Claude Code en sesiones tmux")
struct ClaudeStatusTests {

    // MARK: - Parseo y agregación

    @Test("Parsea list-panes ignorando paneles sin estado y nombres con '|'")
    func parsesPanes() {
        let output = """
        waiting|1|api
        |2|api
        done|1|web|front
        working|3|api
        basura|1|x
        """
        let snapshot = ClaudeActivitySnapshot(listPanesOutput: output)
        #expect(snapshot.activity(forSession: "api") == .waiting)
        #expect(snapshot.activity(forSession: "web|front") == .done)
        #expect(snapshot.activity(forSession: "x") == nil)
        #expect(snapshot.windows(forSession: "api") == [1: .waiting, 3: .working])
    }

    @Test("Prioridad por sesión: esperando > terminó > trabajando")
    func priority() {
        let snapshot = ClaudeActivitySnapshot(listPanesOutput: "working|1|s\ndone|2|s")
        #expect(snapshot.activity(forSession: "s") == .done)
        let withWaiting = ClaudeActivitySnapshot(listPanesOutput: "done|1|s\nwaiting|2|s\nworking|3|s")
        #expect(withWaiting.activity(forSession: "s") == .waiting)
    }

    @Test("Solo notifica al ENTRAR en esperando/terminó, no al seguir igual ni al trabajar")
    func transitions() {
        let old = ClaudeActivitySnapshot(listPanesOutput: "working|1|a\nwaiting|1|b\nworking|1|c")
        let new = ClaudeActivitySnapshot(listPanesOutput: "done|1|a\nwaiting|1|b\nworking|1|c\nwaiting|1|d")
        let changes = new.notableTransitions(since: old)
        #expect(changes == [
            ClaudeTransition(session: "a", activity: .done),
            ClaudeTransition(session: "d", activity: .waiting),
        ])
    }

    // MARK: - Hooks en settings.json

    @Test("Instalar añade los hooks y conserva los existentes del usuario")
    func installMergesWithExisting() throws {
        let existing = """
        {"model":"opus","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 transcribe.py"}]}]}}
        """
        let settings = try ClaudeHookInstaller.parseSettings(existing)
        #expect(!ClaudeHookInstaller.isInstalled(in: settings))

        let installed = ClaudeHookInstaller.installing(into: settings)
        #expect(ClaudeHookInstaller.isInstalled(in: installed))
        #expect(installed["model"] as? String == "opus")

        let hooks = try #require(installed["hooks"] as? [String: Any])
        let submit = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        let commands = submit.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        #expect(commands.contains("python3 transcribe.py"))
        #expect(commands.contains { $0.contains(ClaudeHookInstaller.marker) })
        for event in ["Stop", "PermissionRequest", "Notification", "PostToolUse", "SessionEnd"] {
            #expect(hooks[event] != nil, "falta \(event)")
        }
    }

    @Test("Instalar dos veces no duplica los hooks (idempotente)")
    func installIsIdempotent() throws {
        let once = ClaudeHookInstaller.installing(into: [:])
        let twice = ClaudeHookInstaller.installing(into: once)
        let a = try ClaudeHookInstaller.serialize(once)
        let b = try ClaudeHookInstaller.serialize(twice)
        #expect(a == b)
    }

    @Test("Desinstalar quita solo los hooks de Argos")
    func uninstallKeepsUserHooks() throws {
        let existing = try ClaudeHookInstaller.parseSettings("""
        {"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 transcribe.py"}]}]}}
        """)
        let removed = ClaudeHookInstaller.removing(from: ClaudeHookInstaller.installing(into: existing))
        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(Array(hooks.keys) == ["UserPromptSubmit"])
        #expect(!ClaudeHookInstaller.isInstalled(in: removed))
    }

    @Test("settings.json vacío o inexistente cuenta como objeto vacío")
    func emptySettings() throws {
        #expect(try ClaudeHookInstaller.parseSettings("").isEmpty)
        #expect(try ClaudeHookInstaller.parseSettings("  \n").isEmpty)
    }

    @Test("settings.json inválido lanza (nunca se sobrescribe a ciegas)")
    func invalidSettingsThrows() {
        #expect(throws: ClaudeHookError.invalidSettings) {
            try ClaudeHookInstaller.parseSettings("{ no es json")
        }
        #expect(throws: ClaudeHookError.invalidSettings) {
            try ClaudeHookInstaller.parseSettings("[1, 2]")
        }
    }

    @Test("El comando del hook escribe la opción en el panel de tmux y nunca falla")
    func hookCommand() {
        let command = ClaudeHookInstaller.command(setting: .waiting)
        #expect(command.contains("tmux set-option -p -t \"$TMUX_PANE\" @argos_claude waiting"))
        #expect(command.contains("exit 0"))
        #expect(ClaudeHookInstaller.command(setting: nil).contains("set-option -pu"))
    }
}
