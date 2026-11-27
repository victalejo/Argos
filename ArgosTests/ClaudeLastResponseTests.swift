//
//  ClaudeLastResponseTests.swift
//  ArgosTests
//
//  «Copiar la salida del último comando» con Claude Code: la pantalla real de un panel
//  (Claude redibuja en su sitio y tmux solo guarda lo visible) y el transcript `.jsonl`,
//  con el comando remoto ejecutado de verdad en un HOME temporal.
//

import Foundation
import Testing
@testable import Argos

/// Captura real de `tmux capture-pane -p -J -S -400` de un panel con Claude Code.
enum ClaudePaneFixture {
    static let lines: [String] = [
        "  Desde ese momento, cada «Emitir y cobrar» cobra la tarjeta nueva sin tocar nada en el Manager.",
        "",
        "  Cómo dárselo (lo activa Sebastián en el Dashboard de Stripe):",
        "  - Settings → Billing → Customer portal. Ahí enciende «Customers can update payment methods» y activa el",
        "    link de inicio de sesión.",
        "  - Ese link es fijo. El cliente entra con el email que tiene registrado en Stripe (OdontoExpress sí tiene",
        "    uno), recibe un código y gestiona sus tarjetas.",
        "",
        "  Probé que la llave puede crear sesiones del portal para ese cliente, pero esos links vencen en minutos. Por",
        "  eso no sirven para mandar por WhatsApp; el link fijo del Dashboard sí. Lo que no pude comprobar con la",
        "  llave es si la opción de cambiar el método de pago ya está encendida. Hay que revisarlo en esa misma",
        "  pantalla.",
        "",
        "  Texto para Sebastián:",
        "",
        "  ▎ Pagando por el link de la factura, Stripe cobra pero no le guarda la tarjeta a OE. Hoy OE solo tiene una ",
        "  ▎ cuenta de Stripe Link (la que falló por fondos), y el Manager siempre cobra con la predeterminada.",
        "  ▎ Para que la nueva quede como única: en Stripe → Settings → Billing → Customer portal, activa «actualizar ",
        "  ▎ método de pago» y el link de inicio de sesión, y mándale ese link a OE. Entran con el email que tienen en",
        "  ▎ Stripe, agregan la tarjeta nueva como predeterminada, borran la vieja y ahí mismo pagan la factura de ",
        "  ▎ octubre. Desde ahí, cuando le des «Emitir y cobrar» a noviembre, cobra la nueva.",
        "",
        "  ¿Se lo mando?",
        "",
        "✻ Baked for 1m 51s · done 12:29 PM",
        "",
        "❯ si pero mas ntaruar sin tanto corchete                                                                     ",
        "",
        "  Called waha ",
        "",
        "● Ya se lo mandé a Sebastián, con un tono más natural y sin comillas ni flechas. Le expliqué por qué la",
        "  tarjeta no le queda guardada a OE si paga por el link de la factura. También le dije cómo activar el portal",
        "  de cliente en Stripe, para que OE deje la tarjeta nueva como única y desde ahí pague octubre. Con eso,",
        "  noviembre se cobra a la tarjeta nueva cuando le dé Emitir y cobrar.",
        "",
        "✻ Sautéed for 8s · done 12:30 PM",
        "                                                                       new task? /clear to save 266k tokens",
        "─────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "❯\u{00A0}",
        "─────────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
    ]
}

@Suite("Última respuesta de Claude (pantalla)")
struct ClaudeScreenResponseTests {

    @Test func pantallaRealConLaRespuestaEntera() throws {
        let response = try #require(ClaudeResponseExtractor.lastResponse(lines: ClaudePaneFixture.lines))
        #expect(!response.isPartial)
        #expect(response.text.hasPrefix("Ya se lo mandé a Sebastián, con un tono más natural"))
        #expect(response.text.hasSuffix("noviembre se cobra a la tarjeta nueva cuando le dé Emitir y cobrar."))
        #expect(!response.text.contains("✻") && !response.text.contains("new task?") && !response.text.contains("Called"))
        #expect(!ClaudeResponseExtractor.isWorking(lines: ClaudePaneFixture.lines))
    }

    @Test func siLaRespuestaEmpezoArribaCopiaLaParteVisible() throws {
        // Solo se ve el final de la respuesta anterior y la caja (sin su «●» ni el «❯»).
        let visible = Array(ClaudePaneFixture.lines[0..<25]) + Array(ClaudePaneFixture.lines[36...])
        let response = try #require(ClaudeResponseExtractor.lastResponse(lines: visible))
        #expect(response.isPartial)
        #expect(response.text.hasPrefix("Desde ese momento, cada «Emitir y cobrar» cobra la tarjeta nueva"))
        #expect(response.text.hasSuffix("¿Se lo mando?"))
        #expect(response.text.contains("▎ Pagando por el link de la factura"))
        #expect(!response.text.contains("✻") && !response.text.contains("new task?") && !response.text.contains("⏵⏵"))
    }

    @Test func soloQuitaLasHerramientasConSuFormatoExacto() throws {
        let lines = [
            "  Called claude-in-chrome 6 times (ctrl+o to expand)",
            "  Called the API twice and it failed.",
            "  * una viñeta",
            "  - otra viñeta",
            "",
            "✻ Baked for 1m 51s · done 12:29 PM",
            "                                    new task? /clear to save 199.9k tokens",
        ]
        let response = try #require(ClaudeResponseExtractor.lastResponse(lines: lines))
        #expect(response == .init(text: "Called the API twice and it failed.\n* una viñeta\n- otra viñeta", isPartial: true))
        #expect(ClaudeResponseExtractor.isToolCall(["● Called waha"]))
        #expect(!ClaudeResponseExtractor.isToolCall(["● Called the API twice and it failed."]))
        #expect(ClaudeResponseExtractor.withoutTrailingStatus(["  texto", "  ✻ Worked for 3s", "new task? /clear to save 1k tokens"]) == ["  texto"])
        #expect(ClaudeResponseExtractor.isUserMessage("❯\u{00A0}hola"))
    }

    @Test func sinSenalDeRespuestaNoCopiaNada() {
        let welcome = [
            "╭───────────────────────────────────────────╮",
            "│ ✻ Welcome to Claude Code!                 │",
            "│   /help for help, /status for your setup   │",
            "╰───────────────────────────────────────────╯",
            "  Tips for getting started:",
            "  1. Ask Claude to create a new app",
            "",
            "──────────────────────────────────────────────",
            "❯\u{00A0}",
            "──────────────────────────────────────────────",
        ]
        #expect(ClaudeResponseExtractor.lastResponse(lines: welcome) == nil)
        #expect(ClaudeResponseExtractor.lastResponse(lines: ["❯ pregunta sin respuesta", "", "  Called waha"]) == nil)
        #expect(ClaudeResponseExtractor.lastResponse(lines: ["❯ haz algo", "● Bash(ls)", "  ⎿  a.txt"]) == nil, "solo herramientas")
    }

    @Test func aMitadDeTurnoNoSeCopia() {
        let working = ["❯ haz algo", "", "● Voy a mirarlo.", "", "✢ Pensando… (esc to interrupt)"]
        #expect(ClaudeResponseExtractor.isWorking(lines: working))
        let permission = [
            "● Bash(rm -rf build)",
            "╭──────────────────────────────╮",
            "│ Do you want to proceed?       │",
            "│ ❯ 1. Yes                      │",
            "│   2. No                       │",
            "╰──────────────────────────────╯",
        ]
        #expect(ClaudeResponseExtractor.isWorking(lines: permission))
        let output = "ARGOS_LO_T_n\n" + working.joined(separator: "\n") + "\n"
        #expect(TerminalLastOutput.extract(output, kind: .claude, nonce: "n") == .failure(.inProgress))
    }

    @Test func elAvisoDiceQueEsLaParteVisible() {
        let output = "ARGOS_LO_T_n\n" + Array(ClaudePaneFixture.lines[0..<25]).joined(separator: "\n") + "\n"
        #expect(TerminalLastOutput.extract(output, kind: .claude, nonce: "n").map(\.isPartial) == .success(true))
    }
}

@Suite("Última respuesta de Claude (transcript)")
struct ClaudeTranscriptTests {

    static func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func assistant(id: String, _ blocks: [[String: Any]], sidechain: Bool = false) -> String {
        line(["type": "assistant", "isSidechain": sidechain, "message": ["id": id, "role": "assistant", "content": blocks]])
    }

    static let sample: [String] = [
        assistant(id: "msg_1", [["type": "text", "text": "Respuesta vieja."]]),
        "{\"type\":\"assistant\",roto",
        line(["type": "user", "message": ["role": "user", "content": "otra"]]),
        assistant(id: "msg_2", [["type": "thinking", "thinking": "pienso"]]),
        assistant(id: "msg_2", [["type": "text", "text": "Primera parte."]]),
        assistant(id: "msg_2", [["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]),
        assistant(id: "msg_2", [["type": "text", "text": "Segunda parte\ncon **dos** líneas."]]),
        assistant(id: "sub", [["type": "text", "text": "De un subagente."]], sidechain: true),
        assistant(id: "msg_3", [["type": "tool_use", "name": "Read", "input": [:]]]),
    ]
    static let expected = "Primera parte.\n\nSegunda parte\ncon **dos** líneas."

    /// Pantalla en la que se ve el final de `expected`.
    static let matchingScreen = [
        "● Segunda parte", "  con dos líneas.", "", "✻ Baked for 3s · done",
        "──────────────────────────────────────────", "❯ ", "──────────────────────────────────────────",
    ]

    @Test func uneLosTextosDelUltimoMensajeConTexto() {
        #expect(ClaudeTranscript.lastAssistantText(Self.sample) == Self.expected)
        #expect(ClaudeTranscript.lastAssistantText(["basura", Self.assistant(id: "x", [["type": "tool_use"]])]) == nil)
        #expect(ClaudeTranscript.lastAssistantText([]) == nil)
    }

    @Test func siLaLineaMasRecienteNoSeLeeNoSeFiaDeLasAnteriores() {
        #expect(ClaudeTranscript.lastAssistantText(Self.sample + ["{\"type\":\"assistant\",cortada"]) == nil)
        let huge = Self.assistant(id: "big", [["type": "text", "text": String(repeating: "x", count: ClaudeTranscript.maxLineLength)]])
        #expect(ClaudeTranscript.lastAssistantText(Self.sample + [huge]) == nil)
    }

    @Test func soloLeeEntreSusMarcasYConFin() {
        let output = "ruido\nARGOS_CT_n|file|a.jsonl|2\nuno\nARGOS_CT_n|end\n"
        #expect(ClaudeTranscript.excerpt(in: output, nonce: "n") == .init(lines: ["uno"], recentSessions: 2))
        #expect(ClaudeTranscript.excerpt(in: "ARGOS_CT_n|file|a.jsonl|1\nuno\n", nonce: "n") == nil, "sin |end")
        #expect(ClaudeTranscript.excerpt(in: "ARGOS_CT_n|none\n", nonce: "n") == nil)
        #expect(ClaudeTranscript.excerpt(in: output, nonce: "otro") == nil)
    }

    @Test func clavesDeCarpetaComoClaudeCode() {
        #expect(ClaudeTranscript.folderKeys(for: "/srv/año.x_1") == ["-srv-a-o-x-1", "-srv-año-x_1"])
        #expect(ClaudeTranscript.folderKeys(for: "/home/v/app") == ["-home-v-app"])
        #expect(ClaudeTranscript.folderKeys(for: "/a/😀") == ["-a---", "-a-😀"], "un emoji son dos unidades UTF-16")
    }

    @Test func decideEntreTranscriptYPantalla() {
        func transcript(recent: Int) -> String {
            "ARGOS_CT_n|file|s.jsonl|\(recent)\n" + Self.sample.joined(separator: "\n") + "\nARGOS_CT_n|end\n"
        }
        func screen(_ lines: [String]) -> String { "ARGOS_LO_T_n\n" + lines.joined(separator: "\n") + "\n" }
        // Cuadra con la pantalla: el texto entero del transcript.
        #expect(TerminalLastOutput.extractClaude(screenOutput: screen(Self.matchingScreen), transcriptOutput: transcript(recent: 3), nonce: "n")
            == .success(.init(text: Self.expected)))
        // No cuadra (otra sesión): la pantalla.
        let other = ["● Otra cosa distinta.", "", "✻ Baked for 3s · done"]
        #expect(TerminalLastOutput.extractClaude(screenOutput: screen(other), transcriptOutput: transcript(recent: 1), nonce: "n")
            == .success(.init(text: "Otra cosa distinta.")))
        // Sin nada reconocible en pantalla y varias sesiones activas: dudoso.
        let blank = ["", "──────────────────────────────────────────", "❯ ", "──────────────────────────────────────────"]
        var uncertain = TerminalLastOutput.Extracted(text: Self.expected)
        uncertain.isUncertain = true
        #expect(TerminalLastOutput.extractClaude(screenOutput: screen(blank), transcriptOutput: transcript(recent: 2), nonce: "n")
            == .success(uncertain))
        #expect(TerminalLastOutput.extractClaude(screenOutput: screen(blank), transcriptOutput: transcript(recent: 1), nonce: "n")
            == .success(.init(text: Self.expected)))
        // Trabajando: nada, aunque el transcript tenga el turno anterior.
        let working = Self.matchingScreen + ["  ⏵⏵ bypass permissions on · esc to interrupt"]
        #expect(TerminalLastOutput.extractClaude(screenOutput: screen(working), transcriptOutput: transcript(recent: 1), nonce: "n")
            == .failure(.inProgress))
    }

    /// Los comandos de verdad (sh y, si está, dash) con un HOME temporal y un `tmux` falso
    /// que dice la carpeta del panel y enseña la pantalla.
    @Test(arguments: ["/bin/sh", "/bin/dash"])
    func losComandosLeenElTranscriptMasReciente(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        // Concatenado a mano: `URL.path` devolvería la «ñ» descompuesta (n + tilde).
        let projectPath = home.path + "/mi.proyecto_\u{00F1}"
        let key = try #require(ClaudeTranscript.folderKeys(for: projectPath).first)
        #expect(key.hasSuffix("-mi-proyecto--"))
        let folder = home.appendingPathComponent(".claude/projects/\(key)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Self.assistant(id: "viejo", [["type": "text", "text": "De otra sesión."]])
        try (old + "\n").write(to: folder.appendingPathComponent("vieja.jsonl"), atomically: true, encoding: .utf8)
        // Más de `tailBytes`, con una primera línea larga de «ñ»: el corte cae a mitad de carácter.
        let filler = "{\"type\":\"user\",\"text\":\"" + String(repeating: "ñ", count: ClaudeTranscript.tailBytes / 2 + 10) + "\"}"
        let content = ([filler] + Self.sample).joined(separator: "\n") + "\n"
        try content.write(to: folder.appendingPathComponent("nueva.jsonl"), atomically: true, encoding: .utf8)
        _ = try LocalShell.run("touch -t 202001010000 \(ShellQuoting.singleQuoted(folder.appendingPathComponent("vieja.jsonl").path))", home: home)

        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let screenRows = Self.matchingScreen.map(ShellQuoting.singleQuoted).joined(separator: " ")
        let fakeTmux = """
            #!/bin/sh
            case "$*" in
              *display*) printf '%s\\n' \(ShellQuoting.singleQuoted(projectPath)) ;;
              *capture-pane*) printf '%s\\n' \(screenRows) ;;
            esac
            """
        try fakeTmux.write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
        _ = try LocalShell.run("chmod +x bin/tmux", home: home)

        func run(_ script: String) throws -> String {
            let result = try LocalShell.run("PATH=\"$HOME/bin:$PATH\" \(shell) -c \(ShellQuoting.singleQuoted(script))", home: home)
            #expect(result.exitCode == 0, "\(result.stderr)")
            return result.stdout
        }
        let screenCommand = TerminalLastOutput.command(target: TerminalPaneTarget(session: "s", window: 0), kind: .claude, navigateMarks: false, nonce: "n")
        let screenOutput = try run(screenCommand)
        let path = ClaudeTranscript.panePath(in: screenOutput.components(separatedBy: "\n"), nonce: "n")
        #expect(path == projectPath)
        let transcriptOutput = try run(ClaudeTranscript.readCommand(keys: ClaudeTranscript.folderKeys(for: projectPath), nonce: "n"))
        #expect(ClaudeTranscript.excerpt(in: transcriptOutput, nonce: "n")?.recentSessions == 1)
        #expect(TerminalLastOutput.extractClaude(screenOutput: screenOutput, transcriptOutput: transcriptOutput, nonce: "n")
            == .success(.init(text: Self.expected)))

        // Sin transcript: `none`, y se usa la pantalla.
        try FileManager.default.removeItem(at: folder)
        let none = try run(ClaudeTranscript.readCommand(keys: ClaudeTranscript.folderKeys(for: projectPath), nonce: "n"))
        #expect(none.contains("ARGOS_CT_n|none"))
        #expect(TerminalLastOutput.extractClaude(screenOutput: screenOutput, transcriptOutput: none, nonce: "n")
            == .success(.init(text: "Segunda parte\ncon dos líneas.")))
    }
}
