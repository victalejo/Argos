//
//  ClaudeTaskModelDispatcherTests.swift
//  ArgosTests
//
//  El despachador real con un tmux propio escribiendo `/model` y `/effort` en la terminal
//  y restaurándolos (ver `ClaudeTaskModelScript`). En el panel, un awk hace de Claude Code:
//  apunta lo que le llega y, como el de verdad, guarda `/model` y `/effort` en
//  `~/.claude/settings.json`; con «dialog» enseña un diálogo de permiso.
//

import Testing
import Foundation
@testable import Argos

@Suite("Encargos (modelo en la terminal, con tmux)", .enabled(if: LocalTmux.path != nil), .serialized)
struct ClaudeTaskModelDispatcherTests {

    typealias Box = ClaudeTaskDispatcherTests.Box

    static func fakeClaude(received: String) -> String {
        """
        awk -v f="$HOME/\(received)" -v s="$HOME/.claude/settings.json" '{ print > f; fflush(f)
        if ($0 == "dialog") { print "Do you want to proceed?"; fflush(); next }
        if ($0 == "undialog") { for (i = 0; i < 40; i++) print ""; fflush(); next }
        if (index($0, "/model ") == 1) { m = substr($0, 8); if (m == "default") m = "" }
        else if (index($0, "/effort ") == 1) { e = substr($0, 9); if (e == "auto") e = "" }
        else next
        out = "{"; if (m != "") out = out "\\"model\\":\\"" m "\\""; if (m != "" && e != "") out = out ","
        if (e != "") out = out "\\"effortLevel\\":\\"" e "\\""
        print out "}" > s; close(s) }'
        """
    }

    private static let dispatch = "sh \"$HOME/.config/argos/tasks/dispatch.sh\""

    private func makeBox(settings: String) throws -> Box {
        let box = try Box(fakeClaude: Self.fakeClaude(received: "received"))
        try writeSettings(box, settings)
        return box
    }

    private func writeSettings(_ box: Box, _ json: String) throws {
        let folder = box.home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    private func settings(_ box: Box) -> String {
        (try? String(contentsOf: box.home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)) ?? ""
    }

    private func enqueue(
        _ box: Box, id: String, choice: ClaudeTaskModelChoice,
        project: String = "proyecto", session: String = "proj", prefix: String = ""
    ) throws {
        var request = ClaudeTaskRequest(prompt: "Actualiza dependencias", session: session, window: 0)
        request.modelChoice = choice
        let incoming = box.tasks.appendingPathComponent("incoming")
        try request.prompt.write(to: incoming.appendingPathComponent("\(id).prompt"), atomically: true, encoding: .utf8)
        try request.metaText(directory: box.home.path).write(to: incoming.appendingPathComponent("\(id).meta"), atomically: true, encoding: .utf8)
        try box.sh("\(prefix)\(Self.dispatch) enqueue \(project) \(id)")
    }

    private func pane(_ box: Box, session: String) -> String {
        (try? box.sh("tmux list-panes -t \(session) -F '#{pane_id}'"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Lo que haría el hook del indicador al acabar el turno, y luego el del despachador.
    private func stop(_ box: Box, session: String = "proj") throws {
        let pane = pane(box, session: session)
        try box.sh("tmux set-option -p -t \(pane) @argos_claude done")
        try box.sh("\(Self.dispatch) stop \(pane)", input: "{}")
    }

    private func text(_ box: Box, _ file: String = "received") -> String {
        (try? String(contentsOf: box.home.appendingPathComponent(file), encoding: .utf8)) ?? ""
    }

    private func lines(_ box: Box, _ file: String = "received") -> [String] {
        text(box, file).split(separator: "\n").map(String.init)
    }

    private func waitFor(seconds: Double = 15, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { Thread.sleep(forTimeInterval: 0.2) }
    }

    private var registry: String { ClaudeTaskModelScript.registryRelativePath }

    private func registryExists(_ box: Box) -> Bool {
        FileManager.default.fileExists(atPath: box.home.appendingPathComponent(registry).path)
    }

    @Test func escribeModelYEffortAntesDelEncargoYLosRestaura() throws {
        let box = try makeBox(settings: "{\n  \"model\": \"sonnet\",\n  \"env\": { \"model\": \"x\" }\n}\n")
        defer { box.close() }

        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku, effort: .low))
        waitFor { text(box).contains("Actualiza dependencias") }
        #expect(Array(lines(box).prefix(3)) == ["/model haiku", "/effort low", "Actualiza dependencias"])
        #expect(registryExists(box))

        try stop(box)
        waitFor { text(box).contains("/effort auto") }
        #expect(Array(lines(box).suffix(2)) == ["/model sonnet", "/effort auto"], "vuelve a lo guardado; sin esfuerzo guardado, auto")
        #expect(settings(box) == #"{"model":"sonnet"}"# + "\n")
        waitFor(seconds: 5) { !registryExists(box) }
        #expect(!registryExists(box), "el registro se borra con el último")
        #expect(try box.list().first?.modelNote == nil)
    }

    @Test func dosProyectosNoCorrompenElModeloPorDefecto() throws {
        let box = try makeBox(settings: #"{"model":"sonnet"}"#)
        defer { box.close() }
        try box.sh("tmux new-session -d -s proj2 -x 120 -y 30 \(ShellQuoting.singleQuoted(Self.fakeClaude(received: "received2")))")
        Thread.sleep(forTimeInterval: 0.4)

        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku))
        waitFor { text(box).contains("Actualiza dependencias") }
        try enqueue(box, id: "bbb", choice: ClaudeTaskModelChoice(model: .opus), project: "proyecto2", session: "proj2")
        waitFor { text(box, "received2").contains("Actualiza dependencias") }
        #expect(lines(box, "received2").first == "/model opus")
        #expect(settings(box).contains("opus"))

        // Termina el primero: su ventana vuelve al original, no al de la otra.
        try stop(box)
        waitFor { lines(box).last == "/model sonnet" }
        #expect(lines(box).last == "/model sonnet")
        #expect(registryExists(box), "el segundo sigue con el suyo")

        try stop(box, session: "proj2")
        waitFor { lines(box, "received2").last == "/model sonnet" }
        #expect(lines(box, "received2").last == "/model sonnet", "el original es el de antes del PRIMER encargo, no Haiku")
        #expect(settings(box).contains("sonnet"))
        waitFor(seconds: 3) { !registryExists(box) }
        #expect(!registryExists(box))
    }

    @Test func conUnDialogoAbiertoNoEscribeYAlFinalLoAbandona() throws {
        let box = try makeBox(settings: #"{"model":"sonnet"}"#)
        defer { box.close() }
        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku))
        waitFor { text(box).contains("Actualiza dependencias") }

        // Un diálogo de permiso en pantalla: un Enter lo respondería.
        try box.sh("tmux send-keys -t \(box.pane) -l dialog; tmux send-keys -t \(box.pane) Enter")
        try stop(box)
        Thread.sleep(forTimeInterval: 4)
        #expect(lines(box).last == "dialog", "no escribe /model sobre el diálogo")
        let task = try #require(try box.list().first)
        let restore = box.tasks.appendingPathComponent("proyecto/\(task.folder)/restore")
        #expect(FileManager.default.fileExists(atPath: restore.path), "queda pendiente")

        // Libre otra vez: lo restaura (el reintento tras Stop o el siguiente tick).
        try box.sh("tmux send-keys -t \(box.pane) -l undialog; tmux send-keys -t \(box.pane) Enter")
        try box.sh("\(Self.dispatch) tick")
        waitFor { lines(box).last == "/model sonnet" }
        #expect(lines(box).last == "/model sonnet")

        // Otro encargo que nunca encuentra la ventana libre: pasado el plazo, se abandona.
        try enqueue(box, id: "bbb", choice: ClaudeTaskModelChoice(model: .opus))
        waitFor { text(box).components(separatedBy: "Actualiza dependencias").count == 3 }
        try box.sh("tmux send-keys -t \(box.pane) -l dialog; tmux send-keys -t \(box.pane) Enter")
        try stop(box)
        Thread.sleep(forTimeInterval: 3)
        let second = try #require(try box.list().last)
        let secondRestore = box.tasks.appendingPathComponent("proyecto/\(second.folder)/restore")
        try "model=1\neffort=\nended=1\n".write(to: secondRestore, atomically: true, encoding: .utf8)
        try box.sh("\(Self.dispatch) tick")
        waitFor(seconds: 5) { (try? box.list().last?.modelNote) == .kept }
        #expect(try box.list().last?.modelNote == .kept)
        #expect(!FileManager.default.fileExists(atPath: secondRestore.path))
        #expect(lines(box).last == "dialog")
        #expect(!registryExists(box))
    }

    @Test func siElUsuarioLoCambiaAManoNoLoToca() throws {
        let box = try makeBox(settings: #"{"model":"sonnet"}"#)
        defer { box.close() }
        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku))
        waitFor { text(box).contains("Actualiza dependencias") }
        try writeSettings(box, #"{"model":"claude-opus-4-5[1m]"}"#)
        try stop(box)
        waitFor(seconds: 5) { !registryExists(box) }
        #expect(!registryExists(box))
        #expect(lines(box).last == "Actualiza dependencias")
        #expect(settings(box).contains("claude-opus-4-5[1m]"))
    }

    @Test func unAjusteQueNoSePuedeRestaurarNoSeCambia() throws {
        // Con el awk (sin python3): un `model` de primer nivel que no es un texto.
        let box = try makeBox(settings: #"{"env":{"model":"opus"},"model":{"x":1}}"#)
        defer { box.close() }
        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku), prefix: "ARGOS_MODEL_PARSER=awk ")
        waitFor { text(box).contains("Actualiza dependencias") }
        #expect(lines(box) == ["Actualiza dependencias"])
        #expect(try box.list().first?.modelNote == .unsafe)
        #expect(!registryExists(box))
    }

    @Test func unModeloSoloAnidadoCuentaComoPorDefecto() throws {
        let box = try makeBox(settings: #"{"env":{"model":"opus"}}"#)
        defer { box.close() }
        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku), prefix: "ARGOS_MODEL_PARSER=awk ")
        waitFor { text(box).contains("Actualiza dependencias") }
        try stop(box)
        waitFor { lines(box).last == "/model default" }
        #expect(lines(box) == ["/model haiku", "Actualiza dependencias", "/model default"])
    }

    @Test func siLaVentanaYaNoEsLaDelEncargoNoEscribe() throws {
        let box = try makeBox(settings: #"{"model":"sonnet"}"#)
        defer { box.close() }
        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku))
        waitFor { text(box).contains("Actualiza dependencias") }
        // Como si tmux se hubiera reiniciado y el %N fuera ahora de otra ventana.
        let task = try #require(try box.list().first)
        let meta = box.tasks.appendingPathComponent("proyecto/\(task.folder)/meta")
        let changed = try String(contentsOf: meta, encoding: .utf8).replacingOccurrences(of: "window=0", with: "window=9")
        try changed.write(to: meta, atomically: true, encoding: .utf8)
        try stop(box)
        waitFor(seconds: 5) { (try? box.list().first?.modelNote) == .kept }
        #expect(try box.list().first?.modelNote == .kept)
        #expect(lines(box).last == "Actualiza dependencias")
    }
}
