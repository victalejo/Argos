//
//  TerminalSearchTmuxTests.swift
//  ArgosTests
//
//  Búsqueda en el historial y «Copiar la salida del último comando» contra un tmux local
//  propio (`TMUX_TMPDIR` temporal y corto: el socket no puede pasar de 104 bytes; no toca
//  las sesiones del usuario). Los comandos son los mismos que van al servidor.
//

import Foundation
import Testing
@testable import Argos

/// tmux aislado con una sesión `proj`.
final class LocalTmuxBox: @unchecked Sendable {
    let home: URL
    let socketDirectory: URL
    let env: [String: String]

    init(command: String = "sh", extraEnv: [String: String] = [:]) throws {
        home = try LocalShell.makeTemporaryDirectory()
        socketDirectory = URL(fileURLWithPath: "/tmp/at-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        let bin = ((LocalTmux.path ?? "/usr/bin/tmux") as NSString).deletingLastPathComponent
        env = ["HOME": home.path, "TMUX_TMPDIR": socketDirectory.path, "PATH": "\(bin):/usr/bin:/bin", "PS1": "$ ", "TERM": "xterm-256color"]
            .merging(extraEnv) { $1 }
        try run("tmux -f /dev/null new-session -d -s proj -x 100 -y 20 \(ShellQuoting.singleQuoted(command))")
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Ejecuta `script` con sh; lanza si sale con error (como `runTerminalCommand`).
    @discardableResult
    func run(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SSHService.SSHServiceError.commandFailed(exitCode: Int(process.terminationStatus), message: detail)
        }
        return String(decoding: data, as: UTF8.self)
    }

    var runner: TerminalSearchModel.Runner { { [self] script in try self.run(script) } }

    /// Teclea `line` en el panel activo de la ventana y espera a que aparezca `marker`.
    func type(_ line: String, window: Int = 0, until marker: String) throws {
        try run("tmux send-keys -t \(ShellQuoting.singleQuoted("=proj:\(window)")) \(ShellQuoting.singleQuoted(line)) Enter")
        for _ in 0..<50 {
            if try capture(window: window).contains(marker) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func capture(window: Int = 0) throws -> String {
        try run("tmux capture-pane -p -S - -t \(ShellQuoting.singleQuoted("=proj:\(window)"))")
    }

    func paneInMode(window: Int = 0) throws -> Bool {
        try run("tmux display -p -t \(ShellQuoting.singleQuoted("=proj:\(window)")) '#{pane_in_mode}'")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func close() {
        _ = try? run("tmux kill-server")
        LocalShell.remove(home)
        LocalShell.remove(socketDirectory)
    }
}

@Suite("Búsqueda en el historial (tmux real)", .enabled(if: LocalTmux.path != nil), .serialized)
@MainActor
struct TerminalSearchTmuxTests {

    /// 15 líneas con «hola» y una con «HOLA»; la orden tecleada no contiene la palabra.
    private func makeBox() throws -> LocalTmuxBox {
        let box = try LocalTmuxBox()
        try box.type("i=0; while [ $i -lt 15 ]; do echo \"linea $i h\"\"ola\"; i=$((i+1)); done; echo \"H\"\"OLA grande\"; echo fi\"n\"", until: "\nfin")
        return box
    }

    private func search(_ model: TerminalSearchModel, _ text: String, _ options: TerminalSearchOptions = .init()) async {
        model.options = options
        model.query = text
        model.searchNow()
        await model.waitForPendingWork()
    }

    @Test func cuentaResaltaYSaltaEntreCoincidencias() async throws {
        let box = try makeBox()
        defer { box.close() }
        let model = TerminalSearchModel(sessionName: "proj", debounce: .zero, run: box.runner)
        model.present(window: 0)

        await search(model, "hola")
        #expect(model.status == .found(count: 16, current: 1, partial: false))
        #expect(try box.paneInMode(), "tmux está en modo copia resaltando")

        model.next()
        await model.waitForPendingWork()
        #expect(model.status == .found(count: 16, current: 2, partial: false))
        model.next()
        await model.waitForPendingWork()
        model.previous()
        await model.waitForPendingWork()
        #expect(model.status == .found(count: 16, current: 2, partial: false))

        await search(model, "hola", .init(caseSensitive: true))
        #expect(model.status == .found(count: 15, current: 1, partial: false))
        await search(model, "HOLA", .init(caseSensitive: true))
        #expect(model.status == .found(count: 1, current: 1, partial: false))
        await search(model, "linea 1[0-4] hola", .init(regex: true))
        #expect(model.status == .found(count: 5, current: 1, partial: false))
        await search(model, "no-esta-en-ningun-sitio")
        #expect(model.status == .noMatches)

        let copied = await { () async -> String? in
            await search(model, "linea 1[23] ", .init(regex: true))
            return await model.matchingText()
        }()
        #expect(copied == "linea 12 hola\nlinea 13 hola")

        model.dismiss()
        await model.waitForPendingWork()
        #expect(try !box.paneInMode(), "al cerrar sale del modo copia")
    }

    @Test func siElUsuarioSaleDelModoCopiaVuelveABuscar() async throws {
        let box = try makeBox()
        defer { box.close() }
        let model = TerminalSearchModel(sessionName: "proj", debounce: .zero, run: box.runner)
        model.present(window: 0)
        await search(model, "hola")
        try box.run("tmux send-keys -t '=proj:0' -X cancel")
        model.next()
        await model.waitForPendingWork()
        #expect(model.status == .found(count: 16, current: 1, partial: false))
        model.dismiss()
        await model.waitForPendingWork()
    }

    @Test func buscaEnTodasLasVentanasYSaltaALaElegida() async throws {
        let box = try makeBox()
        defer { box.close() }
        try box.run("tmux new-window -t '=proj' -n segunda sh")
        Thread.sleep(forTimeInterval: 0.4)
        try box.type("echo \"ze\"\"ta uno\"; echo \"ze\"\"ta dos\"; echo lis\"to\"", window: 1, until: "\nlisto")
        try box.type("echo \"ze\"\"ta cero\"; echo lis\"to\"", window: 0, until: "\nlisto")

        let model = TerminalSearchModel(sessionName: "proj", debounce: .zero, run: box.runner)
        model.present(window: 0)
        await search(model, "zeta", .init(allWindows: true))
        #expect(model.status == .found(count: 3, current: nil, partial: false))
        #expect(model.windowResults.map(\.windowIndex) == [0, 1])
        #expect(model.windowResults[1].windowName == "segunda")
        #expect(model.windowResults[1].lines.map(\.text) == ["zeta dos", "zeta uno"])
        let copied = await model.matchingText()
        let firstName = model.windowResults[0].windowName
        #expect(copied == "# 0: \(firstName)\nzeta cero\n\n# 1: segunda\nzeta uno\nzeta dos")

        let older = model.windowResults[1].lines[1]
        model.open(older, in: model.windowResults[1])
        await model.waitForPendingWork()
        let active = try box.run("tmux display -p -t '=proj:' '#{window_index}'").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(active == "1")
        #expect(model.status == .found(count: 2, current: 2, partial: false), "saltó a «zeta uno»")
        #expect(model.target == TerminalPaneTarget(session: "proj", window: 1))
        model.dismiss()
        await model.waitForPendingWork()
        #expect(try !box.paneInMode(window: 1))
    }
}

@Suite("Copiar la última salida (tmux real)", .enabled(if: LocalTmux.path != nil), .serialized)
@MainActor
struct TerminalLastOutputTmuxTests {

    private final class Clipboard: @unchecked Sendable {
        var text: String?
    }

    private func copy(
        _ box: LocalTmuxBox, kind: TerminalLastOutput.Kind, navigateMarks: Bool = false,
        transform: @escaping @Sendable (String) -> String = { $0 }
    ) async -> (String?, TerminalLastOutputModel.State) {
        let runner = box.runner
        let model = TerminalLastOutputModel { script in try await runner(transform(script)) }
        let clipboard = Clipboard()
        await model.copyLastOutput(target: TerminalPaneTarget(session: "proj", window: 0), kind: kind, navigateMarks: navigateMarks) {
            clipboard.text = $0
        }
        return (clipboard.text, model.state)
    }

    @Test func shellSinMarcasConLaHeuristica() async throws {
        let box = try LocalTmuxBox()
        defer { box.close() }
        try box.type("echo uno; echo dos", until: "dos\n")
        try box.type("echo tres; echo cua\"tro\"", until: "cuatro\n")
        let (text, state) = await copy(box, kind: .shell)
        #expect(text == "tres\ncuatro")
        #expect(state == .copied(lines: 2))
    }

    @Test func claudeCopiaSuUltimaRespuesta() async throws {
        let box = try LocalTmuxBox()
        defer { box.close() }
        let screen = [
            "> Explica el error",
            "",
            "⏺ Read(log.txt)",
            "  ⎿  Read 3 lines",
            "",
            "⏺ El error viene de la caché.",
            "  Bórrala y vuelve a compilar.",
            "",
            "────────────────────────────────────────────────",
            "> ",
            "────────────────────────────────────────────────",
            "  ? for shortcuts",
        ].joined(separator: "\n")
        try screen.write(to: box.home.appendingPathComponent("pantalla"), atomically: true, encoding: .utf8)
        try box.type("clear; cat \"$HOME/pantalla\"", until: "for shortcuts")
        let (text, _) = await copy(box, kind: .claude)
        #expect(text == "El error viene de la caché.\nBórrala y vuelve a compilar.")
    }

    /// zsh de verdad con el bloque de Argos en su .zshrc: tmux recibe las marcas OSC 133.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func zshConElBloqueMarcaLaSalida() async throws {
        let rcDirectory = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(rcDirectory) }
        let rc = "PS1='%% '\nunsetopt PROMPT_SP\n" + ShellIntegrationBlock.installing(into: "", shell: .zsh)
        try rc.write(to: rcDirectory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let box = try LocalTmuxBox(command: "zsh -i", extraEnv: ["ZDOTDIR": rcDirectory.path])
        defer { box.close() }
        try box.type("echo uno; echo dos", until: "dos\n")
        try box.type("echo tres; echo cua\"tro\"", until: "cuatro\n")
        Thread.sleep(forTimeInterval: 0.3)

        let flags = try box.run("tmux capture-pane -p -F -S - -t '=proj:0' 2>/dev/null || true")
        if flags.contains("O tres") {
            let (text, _) = await copy(box, kind: .shell)
            #expect(text == "tres\ncuatro", "con capture-pane -F")
        }
        // tmux 3.4/3.5 (sin `capture-pane -F`): el rango con previous-prompt/next-prompt.
        let (ranged, _) = await copy(box, kind: .shell, navigateMarks: true) {
            $0.replacingOccurrences(of: "capture-pane -p -F -S 0 -E 0", with: "capture-pane -p -Z -S 0 -E 0")
        }
        #expect(ranged == "tres\ncuatro", "con el modo copia")
        #expect(try !box.paneInMode(), "deja el panel como estaba")
    }
}
