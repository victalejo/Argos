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

    @Test func herramientasResumidasYAvisoDeLaDerecha() throws {
        let lines = [
            "  Called claude-in-chrome 6 times (ctrl+o to expand)",
            "  - viñeta con * dentro",
            "  * otra viñeta",
            "",
            "✻ Baked for 1m 51s · done 12:29 PM",
            "                                    new task? /clear to save 199.9k tokens",
        ]
        let response = try #require(ClaudeResponseExtractor.lastResponse(lines: lines))
        #expect(response == .init(text: "- viñeta con * dentro\n* otra viñeta", isPartial: true))
        #expect(ClaudeResponseExtractor.withoutTrailingStatus(["  texto", "new task? /clear to save 1k tokens"]) == ["  texto"])
        #expect(ClaudeResponseExtractor.isUserMessage("❯\u{00A0}hola"))
        #expect(ClaudeResponseExtractor.lastResponse(lines: ["❯ pregunta sin respuesta", "", "  Called waha"]) == nil)
    }

    @Test func elAvisoDiceQueEsLaParteVisible() async {
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
        line(["type": "user", "message": ["role": "user", "content": "otra"]]),
        assistant(id: "msg_2", [["type": "thinking", "thinking": "pienso"]]),
        assistant(id: "msg_2", [["type": "text", "text": "Primera parte."]]),
        assistant(id: "msg_2", [["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]),
        assistant(id: "msg_2", [["type": "text", "text": "Segunda parte\ncon dos líneas."]]),
        assistant(id: "msg_3", [["type": "tool_use", "name": "Read", "input": [:]]]),
        assistant(id: "sub", [["type": "text", "text": "De un subagente."]], sidechain: true),
        "{\"type\":\"assistant\",roto",
        "basura",
    ]

    @Test func uneLosTextosDelUltimoMensajeConTexto() {
        #expect(ClaudeTranscript.lastAssistantText(Self.sample) == "Primera parte.\n\nSegunda parte\ncon dos líneas.")
        #expect(ClaudeTranscript.lastAssistantText(["basura", Self.assistant(id: "x", [["type": "tool_use"]])]) == nil)
        #expect(ClaudeTranscript.lastAssistantText([]) == nil)
    }

    @Test func soloLeeEntreSusMarcas() {
        let output = ["ruido", "ARGOS_CT_n|file|a.jsonl", "uno", "ARGOS_CT_n|end", "ARGOS_LO_T_n"]
        #expect(ClaudeTranscript.transcriptLines(in: output, nonce: "n") == ["uno"])
        #expect(ClaudeTranscript.transcriptLines(in: ["ARGOS_CT_n|end"], nonce: "n") == nil)
        #expect(ClaudeTranscript.transcriptLines(in: output, nonce: "otro") == nil)
    }

    /// El comando de verdad (sh y, si está, dash) con un HOME temporal y un `tmux` falso
    /// que dice la carpeta del panel y enseña la pantalla.
    @Test(arguments: ["/bin/sh", "/bin/dash"])
    func elComandoLeeElTranscriptMasReciente(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        let projectPath = home.appendingPathComponent("mi.proyecto_1").path
        let folderName = projectPath.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? String($0) : "-" }.joined()
        let folder = home.appendingPathComponent(".claude/projects/\(folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Self.assistant(id: "viejo", [["type": "text", "text": "De otra sesión."]])
        try (old + "\n").write(to: folder.appendingPathComponent("vieja.jsonl"), atomically: true, encoding: .utf8)
        try (Self.sample.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("nueva.jsonl"), atomically: true, encoding: .utf8)
        _ = try LocalShell.run("touch -t 202001010000 \(ShellQuoting.singleQuoted(folder.appendingPathComponent("vieja.jsonl").path))", home: home)

        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakeTmux = """
            #!/bin/sh
            case "$*" in
              *display*) printf '%s\\n' \(ShellQuoting.singleQuoted(projectPath)) ;;
              *capture-pane*) printf '%s\\n' '  final visible' '✻ Baked for 3s · done' ;;
            esac
            """
        try fakeTmux.write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
        _ = try LocalShell.run("chmod +x bin/tmux", home: home)

        let script = TerminalLastOutput.command(target: TerminalPaneTarget(session: "s", window: 0), kind: .claude, navigateMarks: false, nonce: "n")
        let result = try LocalShell.run("PATH=\"$HOME/bin:$PATH\" \(shell) -c \(ShellQuoting.singleQuoted(script))", home: home)
        #expect(result.exitCode == 0, "\(result.stderr)")
        let extracted = TerminalLastOutput.extract(result.stdout, kind: .claude, nonce: "n")
        #expect(extracted == .success(.init(text: "Primera parte.\n\nSegunda parte\ncon dos líneas.")))

        // Sin transcript: la pantalla, como parte visible.
        try FileManager.default.removeItem(at: folder)
        let screen = try LocalShell.run("PATH=\"$HOME/bin:$PATH\" \(shell) -c \(ShellQuoting.singleQuoted(script))", home: home)
        #expect(TerminalLastOutput.extract(screen.stdout, kind: .claude, nonce: "n") == .success(.init(text: "final visible", isPartial: true)))
    }
}
