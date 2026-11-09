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

    @Test("Parsea el sondeo ignorando paneles sin estado y nombres con '|'")
    func parsesPanes() {
        let output = """
        -|waiting|%1|1|api
        -||%2|2|api
        -|done|%3|1|web|front
        -|working|%4|3|api
        -|basura|%5|1|x
        -|done||1|sin-pane
        """
        let snapshot = ClaudeActivitySnapshot(listPanesOutput: output)
        #expect(snapshot.activity(forSession: "api") == .waiting)
        #expect(snapshot.activity(forSession: "web|front") == .done)
        #expect(snapshot.activity(forSession: "x") == nil)
        #expect(snapshot.activity(forSession: "sin-pane") == nil)
        #expect(snapshot.windows(forSession: "api") == [1: .waiting, 3: .working])
    }

    @Test("Prioridad por sesión: esperando > terminó > trabajando")
    func priority() {
        let snapshot = ClaudeActivitySnapshot(listPanesOutput: "-|working|%1|1|s\n-|done|%2|2|s")
        #expect(snapshot.activity(forSession: "s") == .done)
        let withWaiting = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|1|s\n-|waiting|%2|2|s\n-|working|%3|3|s")
        #expect(withWaiting.activity(forSession: "s") == .waiting)
    }

    @Test("Solo notifica al ENTRAR en esperando/terminó, no al seguir igual ni al trabajar")
    func transitions() {
        let old = ClaudeActivitySnapshot(listPanesOutput: "-|working|%1|1|a\n-|waiting|%2|1|b\n-|working|%3|1|c")
        let new = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|1|a\n-|waiting|%2|1|b\n-|working|%3|1|c\n-|waiting|%4|1|d")
        let changes = new.notableTransitions(since: old)
        #expect(changes == [
            ClaudeTransition(session: "a", window: 1, activity: .done),
            ClaudeTransition(session: "d", window: 1, activity: .waiting),
        ])
    }

    @Test("Una ventana que ya terminó NO oculta el aviso de otra ventana de la sesión")
    func transitionsPerPane() {
        // Antes se agregaba por sesión: con la ventana 1 en «terminó», la 2 pasaba de
        // trabajando a terminó sin que cambiara el agregado y no había aviso.
        let old = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|1|s\n2|working|%2|2|s")
        let new = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|1|s\n-|done|%2|2|s")
        #expect(new.notableTransitions(since: old) == [ClaudeTransition(session: "s", window: 2, activity: .done)])
        let waiting = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|1|s\n-|waiting|%2|2|s")
        #expect(waiting.notableTransitions(since: new) == [ClaudeTransition(session: "s", window: 2, activity: .waiting)])
    }

    @Test("Dos paneles de la misma ventana dan un solo aviso")
    func onePerWindow() {
        let new = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|1|s\n-|done|%2|1|s")
        #expect(new.notableTransitions(since: .empty) == [ClaudeTransition(session: "s", window: 1, activity: .done)])
    }

    @Test("Interrumpido con Esc (sin Stop): ya no se queda «trabajando» y no avisa")
    func interruptedIsQuietDone() {
        let old = ClaudeActivitySnapshot(listPanesOutput: "2|working|%1|1|s")
        let new = ClaudeActivitySnapshot(listPanesOutput: "0|working|%1|1|s")
        #expect(new.activity(forSession: "s") == .done)
        #expect(new.notableTransitions(since: old).isEmpty)
        // Y al terminar de verdad el siguiente turno sí avisa.
        let again = ClaudeActivitySnapshot(listPanesOutput: "2|working|%1|1|s")
        let finished = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|1|s")
        #expect(finished.notableTransitions(since: again) == [ClaudeTransition(session: "s", window: 1, activity: .done)])
    }

    @Test("Corrección con la pantalla", arguments: [
        ("working", "2", ClaudeActivity.working), ("working", "1", .working),
        ("working", "0", .done), ("working", "-", .working),
        ("waiting", "2", .working), ("waiting", "1", .waiting),
        ("waiting", "0", .waiting), ("done", "0", .done),
    ])
    func screenCorrection(hook: String, screen: String, expected: ClaudeActivity) {
        let snapshot = ClaudeActivitySnapshot(listPanesOutput: "\(screen)|\(hook)|%1|1|s")
        #expect(snapshot.activity(forSession: "s") == expected)
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

    @Test("Cubre interrupciones por error y herramientas fallidas")
    func coversFailureEvents() throws {
        let hooks = try #require(ClaudeHookInstaller.installing(into: [:])["hooks"] as? [String: Any])
        for event in ["PostToolUseFailure", "PermissionDenied", "StopFailure"] {
            #expect(hooks[event] != nil, "falta \(event)")
        }
    }

    @Test("Hooks de una versión anterior: no cuentan como instalados, pero sí como nuestros")
    func detectsOutdatedHooks() throws {
        var installed = ClaudeHookInstaller.installing(into: [:])
        var hooks = try #require(installed["hooks"] as? [String: Any])
        hooks["StopFailure"] = nil
        installed["hooks"] = hooks
        #expect(!ClaudeHookInstaller.isInstalled(in: installed))
        #expect(ClaudeHookInstaller.hasAnyOurs(in: installed))
        #expect(ClaudeHookInstaller.isInstalled(in: ClaudeHookInstaller.installing(into: installed)))
        #expect(!ClaudeHookInstaller.hasAnyOurs(in: try ClaudeHookInstaller.parseSettings("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say listo"}]}]}}
        """)))
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
