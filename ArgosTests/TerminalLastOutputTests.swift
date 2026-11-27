//
//  TerminalLastOutputTests.swift
//  ArgosTests
//
//  «Copiar la salida del último comando» (lógica pura): con marcas OSC 133, con la
//  heurística de prompt, la última respuesta de Claude Code y el bloque de los rc.
//

import Foundation
import Testing
@testable import Argos

@Suite("Última salida: shell")
struct ShellOutputExtractorTests {

    @Test func conBanderasDeCapturePane() {
        let lines = ["P $ ls", "O a.txt", "- b.txt", "P $ echo hola", "O hola", "P $ "]
        #expect(ShellOutputExtractor.markedOutput(flaggedLines: lines) == .output("hola"))
        #expect(ShellOutputExtractor.markedOutput(flaggedLines: ["- nada", "- más"]) == .noMarks)
        #expect(ShellOutputExtractor.markedOutput(flaggedLines: ["P $ sleep 9", "O uno", "- dos"]) == .output("uno\ndos"), "sigue corriendo")
        #expect(ShellOutputExtractor.markedOutput(flaggedLines: ["P $ ls", "O x", "OP $ "]) == .output(""), "sin salida")
    }

    @Test func conElRangoDelModoCopia() {
        let rows = ["$ ls", "a", "b", "$ "]
        #expect(ShellOutputExtractor.rangedOutput(rows: rows, firstLine: 10, bottom: 13, start: 11, end: 13) == .output("a\nb"))
        #expect(ShellOutputExtractor.rangedOutput(rows: rows, firstLine: 10, bottom: 13, start: 13, end: 13) == .noMarks)
        #expect(ShellOutputExtractor.rangedOutput(rows: rows, firstLine: 10, bottom: 13, start: 11, end: 11) == .output("a\nb\n$"), "sin prompt siguiente: hasta el final")
        #expect(ShellOutputExtractor.rangedOutput(rows: rows, firstLine: 10, bottom: 13, start: 2, end: 13) == .noMarks)
        #expect(ShellOutputExtractor.absoluteLine("100|20|5") == 85)
        #expect(ShellOutputExtractor.absoluteLine("x") == nil)
    }

    @Test(arguments: [
        (["victor@dev:~/app$ ls", "a.txt", "b.txt", "victor@dev:~/app$ "], "a.txt\nb.txt"),
        (["victor@dev:~$ cd app", "victor@dev:~/app$ git status", "On branch main", "", "victor@dev:~/app$"], "On branch main"),
        (["mac % echo hola", "hola", "mac %"], "hola"),
        (["$ echo $HOME y 5 $ más", "/home/v y 5 $ más", "$ "], "/home/v y 5 $ más"),
        (["~/app on main", "❯ ls", "src", "~/app on main", "❯"], "src"),
        (["root@srv:/# uptime", " 10:00 up 3 days", "root@srv:/# "], " 10:00 up 3 days"),
    ])
    func heuristica(lines: [String], expected: String) {
        #expect(ShellOutputExtractor.heuristicOutput(lines: lines) == expected)
    }

    @Test func heuristicaSinPromptReconocible() {
        #expect(ShellOutputExtractor.heuristicOutput(lines: ["compilando…", "50%"]) == nil)
        #expect(ShellOutputExtractor.heuristicOutput(lines: ["victor@dev:~$ "]) == nil, "sin prompt anterior")
        #expect(ShellOutputExtractor.heuristicOutput(lines: []) == nil)
    }

    @Test func eligeSegunLaSalidaDelComando() {
        let flagged = "ARGOS_LO_F_n\nP $ echo hi\nO hi\nP $ \n"
        #expect(TerminalLastOutput.extract(flagged, kind: .shell, nonce: "n") == .success("hi"))
        let unflagged = "ARGOS_LO_F_n\n- $ echo hi\n- hi\n- $ \n"
        #expect(TerminalLastOutput.extract(unflagged, kind: .shell, nonce: "n") == .success("hi"), "sin marcas: heurística")
        let empty = "ARGOS_LO_F_n\nP $ true\nOP $ \n"
        #expect(TerminalLastOutput.extract(empty, kind: .shell, nonce: "n") == .failure(.empty))
        #expect(TerminalLastOutput.extract("basura", kind: .shell, nonce: "n") == .failure(.notRecognized))
    }

    @Test func conRangoLeeLasFilasAbsolutas() {
        // Historial de 1 línea + 4 visibles: las filas capturadas empiezan en la 0.
        let ranged = "ARGOS_LO_R_n;1|0|3;1|0|1;1|0|3\nARGOS_LO_T_n\nviejo\n$ ls\nuno\ndos\n$ \n"
        #expect(TerminalLastOutput.extract(ranged, kind: .shell, nonce: "n") == .success("uno\ndos"))
    }

    @Test func elComandoEntrecomillaYSoloNavegaSiSePide() {
        let target = TerminalPaneTarget(session: "a'b", window: 1)
        let plain = TerminalLastOutput.command(target: target, kind: .shell, navigateMarks: false, nonce: "n")
        #expect(plain.hasPrefix("t=" + ShellQuoting.singleQuoted("=a'b:1")))
        #expect(!plain.contains("previous-prompt"))
        #expect(TerminalLastOutput.command(target: target, kind: .shell, navigateMarks: true, nonce: "n").contains("previous-prompt -o"))
        let claude = TerminalLastOutput.command(target: target, kind: .claude, navigateMarks: true, nonce: "n")
        #expect(!claude.contains("-F") && !claude.contains("previous-prompt"))
    }
}

@Suite("Última salida: Claude Code")
struct ClaudeResponseExtractorTests {

    @Test func ultimaRespuestaSinCajaNiBarraNiHerramientas() {
        let lines = [
            "> primera pregunta",
            "",
            "⏺ Respuesta vieja.",
            "",
            "> Revisa los tests",
            "  y arréglalos",
            "",
            "⏺ Voy a mirar los tests.",
            "",
            "⏺ Bash(swift test)",
            "  ⎿  Test run with 3 tests passed",
            "",
            "⏺ Listo: los tres tests pasan.",
            "",
            "  - Cambié `foo`.",
            "  - Añadí un caso.",
            "",
            "✻ Worked for 12s",
            "",
            "────────────────────────────────────────────────",
            "> ",
            "────────────────────────────────────────────────",
            "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
        ]
        let expected = "Listo: los tres tests pasan.\n\n- Cambié `foo`.\n- Añadí un caso."
        #expect(ClaudeResponseExtractor.lastResponse(lines: lines) == expected)
    }

    @Test func cajaAntiguaYSinTurnoDelUsuario() {
        let lines = [
            "⏺ Hola, ¿en qué te ayudo?",
            "╭──────────────────────────╮",
            "│ > escribe aquí            │",
            "╰──────────────────────────╯",
            "  ? for shortcuts",
        ]
        #expect(ClaudeResponseExtractor.lastResponse(lines: lines) == "Hola, ¿en qué te ayudo?")
    }

    @Test func soloHerramientasDevuelveLaUltima() {
        let lines = ["> haz algo", "⏺ Read(main.swift)", "  ⎿  Read 20 lines", "", "✢ Pensando… (esc to interrupt)"]
        #expect(ClaudeResponseExtractor.lastResponse(lines: lines) == "Read(main.swift)\n⎿  Read 20 lines")
        #expect(ClaudeResponseExtractor.lastResponse(lines: ["> hola", "nada de claude"]) == nil)
    }

    @Test func reconoceLlamadasAHerramientas() {
        #expect(ClaudeResponseExtractor.isToolCall(["⏺ Update(Sources/a.swift)"]))
        #expect(ClaudeResponseExtractor.isToolCall(["⏺ mcp__github__list(x)"]))
        #expect(ClaudeResponseExtractor.isToolCall(["⏺ Read 3 files (ctrl+o to expand)"]))
        #expect(!ClaudeResponseExtractor.isToolCall(["⏺ El método (privado) falla."]))
        #expect(!ClaudeResponseExtractor.isToolCall(["● Todo bien."]))
    }
}

@Suite("Marcas de prompt (bloque de los rc)")
struct ShellIntegrationBlockTests {

    @Test func instalarEsIdempotenteYQuitarDejaElArchivoComoEstaba() {
        let original = "export PATH=\"$HOME/bin:$PATH\"\nalias ll='ls -l'"
        let installed = ShellIntegrationBlock.installing(into: original, shell: .zsh)
        #expect(installed.hasPrefix(original + "\n\n" + ShellIntegrationBlock.beginMarker))
        #expect(ShellIntegrationBlock.isCurrent(in: installed, shell: .zsh))
        #expect(ShellIntegrationBlock.installing(into: installed, shell: .zsh) == installed, "idempotente")
        #expect(ShellIntegrationBlock.removing(from: installed) == original + "\n")
        #expect(ShellIntegrationBlock.removing(from: original) == original)
        let empty = ShellIntegrationBlock.installing(into: "", shell: .bash)
        #expect(empty == ShellIntegrationBlock.block(for: .bash) + "\n")
        #expect(ShellIntegrationBlock.removing(from: empty) == "")
    }

    @Test func sustituyeUnBloqueViejoEnSuSitioSinTocarLoDemas() {
        let old = "antes\n\(ShellIntegrationBlock.beginMarker)\n# v0\necho viejo\n\(ShellIntegrationBlock.endMarker)\ndespués\n"
        #expect(ShellIntegrationBlock.isInstalled(in: old))
        #expect(!ShellIntegrationBlock.isCurrent(in: old, shell: .zsh))
        let updated = ShellIntegrationBlock.installing(into: old, shell: .zsh)
        #expect(updated == "antes\n" + ShellIntegrationBlock.block(for: .zsh) + "\ndespués\n")
        #expect(ShellIntegrationBlock.removing(from: updated) == "antes\ndespués\n")
    }

    @Test func laMarcaDebeEmpezarLinea() {
        let quoted = "echo '\(ShellIntegrationBlock.beginMarker)' \(ShellIntegrationBlock.endMarker)"
        #expect(!ShellIntegrationBlock.isInstalled(in: quoted))
    }

    private func report(
        shell: String, files: [ShellIntegrationBlock.Shell: ShellRcProbe.FileState] = [:]
    ) -> ShellRcProbe.Report {
        var report = ShellRcProbe.Report()
        report.loginShell = shell
        report.files = [.zsh: .absent, .bash: .absent].merging(files) { $1 }
        report.complete = true
        return report
    }

    @Test func eligeLosRcSegunLoQueHay() throws {
        let rc = ShellRcProbe.FileState.file(Data("x\n".utf8), mode: "644")
        #expect(try ShellRcProbe.targets(report(shell: "/usr/bin/zsh")) == [.zsh])
        #expect(try ShellRcProbe.targets(report(shell: "/bin/bash", files: [.zsh: rc])) == [.zsh, .bash])
        #expect(try ShellRcProbe.targets(report(shell: "/usr/bin/fish", files: [.bash: rc])) == [.bash])
        #expect(throws: ShellIntegrationError.unsupportedShell("fish")) {
            try ShellRcProbe.targets(report(shell: "/usr/bin/fish"))
        }
    }

    @Test func planEscribeConHuellaYConservaPermisos() throws {
        let original = Data("alias ll='ls -l'\n".utf8)
        let edits = try ShellRcEdit.plan(report(shell: "/bin/zsh", files: [.zsh: .file(original, mode: "644")]), enable: true)
        #expect(edits.count == 1)
        #expect(edits[0].expectation == .fingerprint(PosixChecksum.fingerprint(of: original)))
        #expect(edits[0].mode == "644")
        #expect(String(decoding: edits[0].content, as: UTF8.self).hasPrefix("alias ll='ls -l'\n\n# >>> argos"))
        let created = try ShellRcEdit.plan(report(shell: "/bin/bash"), enable: true)
        #expect(created.map(\.expectation) == [.absentOrEmpty])
        let installed = edits[0].content
        let removal = try ShellRcEdit.plan(report(shell: "/bin/zsh", files: [.zsh: .file(installed, mode: "600")]), enable: false)
        #expect(removal.first?.content == original)
        #expect(try ShellRcEdit.plan(report(shell: "/bin/zsh", files: [.zsh: .file(installed, mode: nil)]), enable: true).isEmpty, "ya está")
    }

    @Test func noReescribeEnlacesNiTextoQueNoEsUTF8() {
        #expect(throws: ShellIntegrationError.notRegularFile(".zshrc")) {
            try ShellRcEdit.plan(report(shell: "/bin/zsh", files: [.zsh: .notRegular]), enable: true)
        }
        #expect(throws: ShellIntegrationError.notUTF8(".zshrc")) {
            try ShellRcEdit.plan(report(shell: "/bin/zsh", files: [.zsh: .file(Data([0x61, 0xFF, 0x0A]), mode: "644")]), enable: true)
        }
        var cut = report(shell: "/bin/zsh")
        cut.complete = false
        #expect(throws: ShellIntegrationError.unreadable) { try ShellRcEdit.plan(cut, enable: true) }
    }

    @Test func avisaSiElBloqueNoSeCargaria() {
        var zsh = report(shell: "/usr/bin/zsh")
        zsh.home = "/home/v"
        zsh.zdotdir = "/home/v/.config/zsh"
        #expect(ShellRcProbe.warning(zsh)?.contains("ZDOTDIR") == true)
        zsh.zdotdir = "/home/v/"
        #expect(ShellRcProbe.warning(zsh) == nil)
        var bash = report(shell: "/bin/bash")
        bash.bashLoginProfile = .init(name: ".bash_profile", loadsRc: false)
        #expect(ShellRcProbe.warning(bash)?.contains(".bash_profile") == true)
        bash.bashLoginProfile = .init(name: ".profile", loadsRc: true)
        #expect(ShellRcProbe.warning(bash) == nil)
    }

    /// El script de lectura de verdad, con un HOME temporal: ruido del arranque, bytes que
    /// no son UTF-8, permisos, enlaces simbólicos y duros.
    @Test func elScriptDeLecturaIgnoraElRuidoYDetectaEnlaces() throws {
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        let zshrc = Data([0x65, 0x63, 0x68, 0x6F, 0x20, 0xFF, 0x0A]) // «echo \xFF»
        try zshrc.write(to: home.appendingPathComponent(".zshrc"))
        try "x".write(to: home.appendingPathComponent("real"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".bashrc"), withDestinationURL: home.appendingPathComponent("real"))
        try "if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n".write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        _ = try LocalShell.run("chmod 640 .zshrc", home: home)

        let noisy = "echo 'Bienvenido|ARGOS'; " + ShellQuoting.posixShell(ShellRcProbe.command(nonce: "t1"))
        let result = try LocalShell.run("SHELL=/bin/zsh; export SHELL; " + noisy, home: home)
        #expect(result.exitCode == 0, "\(result.stderr)")
        let report = ShellRcProbe.parse(result.stdout, nonce: "t1")
        #expect(report.complete)
        #expect(report.loginShell == "/bin/zsh")
        #expect(report.files[.zsh] == .file(zshrc, mode: "640"), "bytes intactos y permisos")
        #expect(report.files[.bash] == .notRegular, "enlace simbólico")
        #expect(report.bashLoginProfile == .init(name: ".profile", loadsRc: true))

        try FileManager.default.removeItem(at: home.appendingPathComponent(".bashrc"))
        try FileManager.default.linkItem(at: home.appendingPathComponent("real"), to: home.appendingPathComponent(".bashrc"))
        let hard = ShellRcProbe.parse(try LocalShell.run(noisy, home: home).stdout, nonce: "t1")
        #expect(hard.files[.bash] == .notRegular, "enlace duro")
    }

    @Test(arguments: [(ShellIntegrationBlock.Shell.zsh, "/bin/zsh"), (.bash, "/bin/bash")])
    func elBloqueEsSintaxisValida(shell: ShellIntegrationBlock.Shell, binary: String) throws {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        let file = home.appendingPathComponent("rc")
        try ShellIntegrationBlock.block(for: shell).write(to: file, atomically: true, encoding: .utf8)
        let result = try LocalShell.run("\(binary) -n \(ShellQuoting.singleQuoted(file.path))", home: home)
        #expect(result.exitCode == 0, "\(result.stderr)")
    }
}
