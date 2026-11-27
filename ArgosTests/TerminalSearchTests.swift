//
//  TerminalSearchTests.swift
//  ArgosTests
//
//  Búsqueda en el historial del terminal (lógica pura): el patrón y cómo se le pide a tmux,
//  los comandos (entrecomillado), la posición del cursor, «3 de 12», los resultados por
//  ventana y el modelo de la barra con un tmux simulado.
//

import Foundation
import Testing
@testable import Argos

@Suite("Búsqueda en el terminal (patrón y tmux)")
struct TerminalSearchPatternTests {

    private func pattern(_ text: String, caseSensitive: Bool = false, regex: Bool = false) -> TerminalSearchPattern {
        TerminalSearchPattern(text: text, options: TerminalSearchOptions(caseSensitive: caseSensitive, regex: regex))!
    }

    @Test func vacioOConSaltoDeLineaNoEsPatron() {
        #expect(TerminalSearchPattern(text: "", options: .init()) == nil)
        #expect(TerminalSearchPattern(text: "a\nb", options: .init()) == nil)
    }

    @Test func literalSinDistinguirVaEnMinusculas() {
        let search = pattern("Hola Mundo").tmuxSearch(supportsRegex: true)
        #expect(search == .init(command: "search-backward-text", argument: "hola mundo"))
    }

    @Test func literalDistinguiendoConMayusculasVaTalCual() {
        let search = pattern("Hola", caseSensitive: true).tmuxSearch(supportsRegex: true)
        #expect(search == .init(command: "search-backward-text", argument: "Hola"))
        let digits = pattern("404", caseSensitive: true).tmuxSearch(supportsRegex: true)
        #expect(digits == .init(command: "search-backward-text", argument: "404"))
    }

    @Test func literalDistinguiendoSinMayusculasFuerzaATmux() {
        let search = pattern("a.b", caseSensitive: true).tmuxSearch(supportsRegex: true)
        #expect(search == .init(command: "search-backward", argument: "(a\\.b)|A^"))
    }

    @Test func regexSinDistinguirRespetaLosEscapes() {
        let search = pattern("Err\\S+ [A-Z]", regex: true).tmuxSearch(supportsRegex: true)
        #expect(search == .init(command: "search-backward", argument: "err\\S+ [a-z]"))
    }

    @Test func regexDistinguiendo() {
        #expect(pattern("Err.*", caseSensitive: true, regex: true).tmuxSearch(supportsRegex: true).argument == "Err.*")
        #expect(pattern("err.*", caseSensitive: true, regex: true).tmuxSearch(supportsRegex: true).argument == "(err.*)|A^")
    }

    @Test func tmuxViejoSoloBuscaTexto() {
        #expect(pattern("Hola").tmuxSearch(supportsRegex: false) == .init(command: "search-backward", argument: "hola"))
    }

    @Test func cuentaCoincidenciasComoTmux() throws {
        let lines = ["hola Hola", "nada", "HOLA y hola"]
        let insensitive = TerminalSearchMatcher.matches(in: lines, regex: try pattern("hola").matcher())
        #expect(insensitive.count == 4)
        #expect(insensitive[0] == TerminalSearchMatch(line: 0, start: 0, end: 4))
        let sensitive = TerminalSearchMatcher.matches(in: lines, regex: try pattern("hola", caseSensitive: true).matcher())
        #expect(sensitive.map(\.line) == [0, 2])
    }

    @Test func lasLineasQueCoincidenSinRepetirSeguidas() throws {
        let lines = ["uno err  ", "uno err", "dos", "tres err"]
        let result = TerminalSearchMatcher.matchingLines(in: lines, regex: try pattern("err").matcher())
        #expect(result == ["uno err", "tres err"])
    }

    @Test func unaRegexInvalidaLanza() {
        #expect(throws: (any Error).self) { try pattern("(", regex: true).matcher() }
        #expect(throws: Never.self) { try pattern("(").matcher() }
    }

    @Test func versionDeTmux() {
        #expect(TmuxVersion(versionOutput: "tmux 3.4\n") == TmuxVersion(major: 3, minor: 4))
        #expect(TmuxVersion(versionOutput: "tmux 3.3a") == TmuxVersion(major: 3, minor: 3))
        #expect(TmuxVersion(versionOutput: "tmux next-3.6")?.supportsPromptMarks == true)
        #expect(TmuxVersion(versionOutput: "tmux master")?.supportsRegexSearch == true)
        #expect(TmuxVersion(versionOutput: "tmux 3.0a")?.supportsRegexSearch == false)
        #expect(TmuxVersion(versionOutput: "bash: tmux: not found") == nil)
    }
}

@Suite("Búsqueda en el terminal (comandos y posición)")
struct TerminalSearchCommandTests {

    @Test func elDestinoEsExactoYVaEntrecomillado() {
        #expect(TerminalPaneTarget(session: "app", window: 2).tmuxTarget == "=app:2")
        #expect(TerminalPaneTarget(session: "app", window: nil).tmuxTarget == "=app:")
        let evil = TerminalPaneTarget(session: "x'; rm -rf ~; '", window: nil)
        let search = TerminalSearchPattern.TmuxSearch(command: "search-backward-text", argument: "'; reboot; '")
        let command = TerminalSearchCommands.start(target: evil, search: search, nonce: "n")
        #expect(command.contains("t=" + ShellQuoting.singleQuoted("=x'; rm -rf ~; ':")))
        #expect(command.contains(ShellQuoting.singleQuoted("'; reboot; '")))
        #expect(!command.contains(" reboot; '\n"))
    }

    @Test func pasosHaciaAtrasYAdelante() {
        let target = TerminalPaneTarget(session: "s", window: 0)
        #expect(TerminalSearchCommands.step(target: target, older: true, nonce: "n").contains("-X search-again"))
        #expect(TerminalSearchCommands.step(target: target, older: false, nonce: "n").contains("-X search-reverse"))
        #expect(TerminalSearchCommands.step(target: target, older: true, count: 4, nonce: "n").contains("-X -N 4 search-again"))
    }

    @Test func leeLaPosicion() {
        let position = TerminalSearchPosition(displayLine: "1|13|9|8|9|1\n")
        #expect(position?.inMode == true)
        #expect(position?.line == 12)
        #expect(position?.column == 9)
        #expect(position?.searchPresent == true)
        let old = TerminalSearchPosition(displayLine: "1|13|||| ")
        #expect(old?.line == nil)
        #expect(TerminalSearchPosition(displayLine: "basura") == nil)
    }

    @Test func numeraDesdeLaMasReciente() {
        let matches = [
            TerminalSearchMatch(line: 0, start: 0, end: 4),
            TerminalSearchMatch(line: 3, start: 2, end: 6),
            TerminalSearchMatch(line: 3, start: 10, end: 14),
            TerminalSearchMatch(line: 7, start: 0, end: 4),
        ]
        func index(_ line: Int, _ column: Int, first: Int = 100) -> Int? {
            let position = TerminalSearchPosition(displayLine: "1|\(first)|0|\(line - first)|\(column)|1")
            return TerminalSearchCommands.currentIndex(position: position, matches: matches, firstLine: first)
        }
        #expect(index(107, 0) == 1)
        #expect(index(103, 14) == 2, "al final de la coincidencia (hacia delante)")
        #expect(index(103, 2) == 3)
        #expect(index(100, 1) == 4)
        #expect(index(105, 0) == nil)
    }

    @Test func leeLaSalidaDeUnaBusqueda() {
        let output = """
            ARGOS_TS_POS_abc
            1|25000|0|3|0|1
            ARGOS_TS_TEXT_abc
            uno
            dos

            """
        let snapshot = TerminalSearchCommands.parse(output, nonce: "abc")
        #expect(snapshot?.lines == ["uno", "dos"])
        #expect(snapshot?.firstLine == 5000)
        #expect(snapshot?.isPartial == true)
        #expect(snapshot?.leftCopyMode == false)
        #expect(TerminalSearchCommands.parse(output, nonce: "otro") == nil, "la marca lleva el aleatorio")
        #expect(TerminalSearchCommands.parse("ARGOS_TS_GONE_abc\n", nonce: "abc")?.leftCopyMode == true)
    }
}

@Suite("Búsqueda en todas las ventanas")
struct TerminalWindowSearchTests {

    @Test func agrupaPorVentanaYNoSeDejaEngañar() throws {
        let output = """
            ARGOS_SW_n1|0|zsh
            error uno
            ARGOS_SW_falso|9|trampa
            nada
            ARGOS_SW_n1|2|claude|con barra
            error dos y error tres
            ok
            ARGOS_SW_n1|3|vacía
            sin nada
            """
        let regex = try TerminalSearchPattern(text: "error", options: .init())!.matcher()
        let results = TerminalWindowSearch.results(output, nonce: "n1", regex: regex)
        #expect(results.map(\.windowIndex) == [0, 2])
        #expect(results[1].windowName == "claude|con barra")
        #expect(results[1].matchCount == 2)
        #expect(results[1].lines.map(\.text) == ["error dos y error tres"])
        #expect(results[1].lines[0].ordinalFromNewest == 1)
        #expect(results[0].lines[0].text == "error uno")
    }

    @Test func elOrdinalEsDesdeLaMasReciente() throws {
        let regex = try TerminalSearchPattern(text: "x", options: .init())!.matcher()
        let result = try #require(TerminalWindowSearch.result(index: 1, name: "w", lines: ["x x", "y", "x"], regex: regex))
        #expect(result.lines.map(\.ordinalFromNewest) == [1, 2])
        #expect(TerminalWindowSearch.copyText([result]) == "# 1: w\nx x\nx")
    }

    @Test func elComandoEntrecomillaLaSesion() {
        let command = TerminalWindowSearch.command(session: "a'b", nonce: "n")
        #expect(command.hasPrefix("s=" + ShellQuoting.singleQuoted("=a'b")))
    }
}

/// tmux simulado: responde a los comandos del modelo según lo que piden.
private final class FakeTmux: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    var lines: [String]
    var position: String

    init(lines: [String], position: String) {
        self.lines = lines
        self.position = position
    }

    var received: [String] { lock.withLock { commands } }

    func run(_ command: String) throws -> String {
        lock.withLock { commands.append(command) }
        if command == TerminalSearchCommands.versionCommand { return "tmux 3.4\n" }
        let nonce = Self.nonce(in: command, prefix: "ARGOS_TS_POS_")
        if command.contains("search-backward") {
            return "ARGOS_TS_POS_\(nonce)\n\(position)\nARGOS_TS_TEXT_\(nonce)\n" + lines.joined(separator: "\n") + "\n"
        }
        if command.contains("search-again") || command.contains("search-reverse") {
            return "ARGOS_TS_POS_\(nonce)\n\(position)\n"
        }
        return ""
    }

    static func nonce(in command: String, prefix: String) -> String {
        guard let range = command.range(of: prefix) else { return "" }
        return String(command[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
    }
}

@Suite("Barra de búsqueda (modelo)")
@MainActor
struct TerminalSearchModelTests {

    @Test func buscaCuentaYSeMueve() async {
        let tmux = FakeTmux(lines: ["hola", "otra", "hola hola"], position: "1|0|0|2|5|1")
        let model = TerminalSearchModel(sessionName: "s", debounce: .zero) { try tmux.run($0) }
        model.present(window: 1)
        model.query = "hola"
        model.searchNow()
        await model.waitForPendingWork()
        #expect(model.status == .found(count: 3, current: 1, partial: false))
        #expect(model.statusText == "1 de 3")
        tmux.position = "1|0|0|0|0|1"
        model.next()
        await model.waitForPendingWork()
        #expect(model.status == .found(count: 3, current: 3, partial: false))
        #expect(tmux.received.contains { $0.contains("=s:1") && $0.contains("search-again") })
        model.dismiss()
        await model.waitForPendingWork()
        #expect(tmux.received.last?.contains("-X cancel") == true)
        #expect(model.status == .idle)
    }

    @Test func sinCoincidenciasYRegexInvalida() async {
        let tmux = FakeTmux(lines: ["nada"], position: "1|0|0|0|0|0")
        let model = TerminalSearchModel(sessionName: "s", debounce: .zero) { try tmux.run($0) }
        model.present(window: nil)
        model.query = "hola"
        model.searchNow()
        await model.waitForPendingWork()
        #expect(model.status == .noMatches)
        #expect(!model.canStep)
        model.options.regex = true
        model.query = "("
        model.searchNow()
        await model.waitForPendingWork()
        #expect(model.status == .invalidPattern)
        model.dismiss()
    }

    @Test func unFalloSeMuestra() async {
        let model = TerminalSearchModel(sessionName: "s", debounce: .zero) { _ in
            throw SSHService.SSHServiceError.commandFailed(exitCode: 1, message: "can't find pane")
        }
        model.present(window: 0)
        model.query = "x"
        model.searchNow()
        await model.waitForPendingWork()
        guard case .failed(let message) = model.status else {
            Issue.record("no falló: \(model.status)"); return
        }
        #expect(message.contains("can't find pane"))
    }
}
