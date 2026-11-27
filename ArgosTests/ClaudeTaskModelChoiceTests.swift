//
//  ClaudeTaskModelChoiceTests.swift
//  ArgosTests
//
//  Modelo y esfuerzo por encargo: lista cerrada, guardado aditivo (meta, config, JSON), la
//  línea de `claude` de los agentes y el despachador real escribiendo `/model` en la terminal.
//

import Testing
import Foundation
@testable import Argos

@Suite("Encargos (modelo y esfuerzo)")
struct ClaudeTaskModelChoiceTests {

    private static let choice = ClaudeTaskModelChoice(model: .haiku, effort: .low)

    @Test func soloAceptaValoresDeLaLista() {
        let parsed = ClaudeTaskModelChoice(modelText: "opus; rm -rf ~", effortText: " high ")
        #expect(parsed.model == nil, "texto libre no cuela")
        #expect(parsed.effort == .high)
        #expect(ClaudeTaskModelChoice(modelText: nil, effortText: "ultra").isDefault)
        #expect(Self.choice.cliArguments == ["--model", "haiku", "--effort", "low"])
        #expect(ClaudeTaskModelChoice.default.cliArguments.isEmpty)
        #expect(ClaudeTaskModelChoice.default.keyValueLines.isEmpty)
        #expect(ClaudeTaskModelChoice.default.summary == nil)
        #expect(ClaudeTaskModelChoice(model: .opus).summary == "Opus")
    }

    @Test func unaPlantillaRellenaLoQueFija() {
        let template = SavedPrompt(id: "deps", title: "Deps", text: "Actualiza", model: .haiku)
        let fromTemplate = ClaudeTaskModelChoice(savedPrompt: template)
        #expect(fromTemplate == ClaudeTaskModelChoice(model: .haiku))
        let current = ClaudeTaskModelChoice(model: .opus, effort: .high)
        #expect(current.applying(fromTemplate) == ClaudeTaskModelChoice(model: .haiku, effort: .high), "el esfuerzo elegido se queda")
        #expect(current.applying(.default) == current)

        // Un nivel que la biblioteca aún no conoce (queda en `extra`) vale si está en la lista.
        var newer = SavedPrompt(id: "x", title: "X", text: "Rediseña")
        newer.extra[SavedPrompt.effortKey] = .string("xhigh")
        newer.extra[SavedPrompt.modelKey] = .string("mythos")
        #expect(ClaudeTaskModelChoice(savedPrompt: newer) == ClaudeTaskModelChoice(effort: .xhigh))
    }

    @Test func jsonDeIdaYVueltaYTolerante() throws {
        let data = try JSONEncoder().encode(Self.choice)
        #expect(try JSONDecoder().decode(ClaudeTaskModelChoice.self, from: data) == Self.choice)
        #expect(String(decoding: try JSONEncoder().encode(ClaudeTaskModelChoice.default), as: UTF8.self) == "{}")
        let newer = Data(#"{"model":"mythos","effort":"max","otra":1}"#.utf8)
        #expect(try JSONDecoder().decode(ClaudeTaskModelChoice.self, from: newer) == ClaudeTaskModelChoice(effort: .max))
        let wrongType = Data(#"{"model":3}"#.utf8)
        #expect(try JSONDecoder().decode(ClaudeTaskModelChoice.self, from: wrongType).isDefault)
    }

    @Test func elMetaDelEncargoVaYVuelve() {
        var request = ClaudeTaskRequest(prompt: "Actualiza dependencias", session: "proj", window: 0)
        #expect(!request.metaText(directory: "/srv/app").contains("model="), "por defecto no escribe nada")
        request.modelChoice = Self.choice
        let meta = request.metaText(directory: "/srv/app")
        #expect(meta.contains("model=haiku\n") && meta.contains("effort=low\n"))
        let listing = "@@task -srv-app/000001-abc\nstate pending\n"
            + meta.split(separator: "\n").map { "meta \($0)" }.joined(separator: "\n") + "\nprompt x\n"
        #expect(ClaudeTask.parse(listOutput: listing).first?.modelChoice == Self.choice)
    }

    @Test func losAgentesLlevanModeloYEsfuerzoEnSuLinea() throws {
        let line = ClaudeAgentCommand.persistent(
            claudePath: "/usr/bin/claude", sessionID: "s", resume: false, modelChoice: Self.choice
        )
        #expect(line.hasSuffix("--session-id s --model haiku --effort low"))
        #expect(!ClaudeAgentCommand.persistent(claudePath: "/usr/bin/claude", sessionID: "s", resume: true).contains("--model"))

        var request = ClaudeTaskRequest(prompt: "Rediseña esto", session: "app", window: 0)
        request.modelChoice = ClaudeTaskModelChoice(model: .opus, effort: .max)
        let scripts = try ClaudeTaskAgentScripts.make(
            request: request, agentID: "11111111-2222-4333-8444-555555555555", worktree: "/srv/w",
            branch: "argos/encargo-x", projectPath: "/srv/app", claudePath: "/usr/bin/claude"
        )
        #expect(scripts.launch.contains("--model opus --effort max"))

        var meta = PersistentAgentMeta(workingDirectory: "/w", title: "t", createdAt: Date(timeIntervalSince1970: 0))
        meta.model = "opus"; meta.effort = "raro"
        #expect(meta.modelChoice == ClaudeTaskModelChoice(model: .opus), "reanudar conserva el modelo válido")
    }

    @Test func lasProgramadasGuardanYLeenSuModelo() throws {
        let project = Project(name: "App", path: "/srv/app")
        var schedule = ClaudeSchedule(
            id: "abcd1234", title: "Deps", prompt: "Actualiza dependencias", projectPath: project.path,
            session: "app", weekdays: [1], hour: 3, minute: 0
        )
        schedule.modelChoice = Self.choice
        let files = try ClaudeScheduleScripts.make(schedule, claudePath: "/usr/bin/claude")
        #expect(files.config.contains("model=haiku\n") && files.config.contains("effort=low\n"))
        #expect(files.launch.contains("--model haiku --effort low"))
        #expect(files.meta.contains(#""model" : "haiku""#))
        #expect(files.task.contains("model=haiku\n"))

        let listing = "@@schedule abcd1234\n" + files.config.split(separator: "\n").map { "config \($0)" }.joined(separator: "\n")
        let parsed = ClaudeScheduleScripts.parse(listOutput: listing, projects: [project])
        #expect(parsed.first?.modelChoice == Self.choice)

        schedule.modelChoice = .default
        #expect(!ClaudeScheduleScripts.configText(schedule).contains("model="))
    }
}

@Suite("Encargos (modelo en la terminal, con tmux)", .enabled(if: LocalTmux.path != nil), .serialized)
struct ClaudeTaskModelDispatcherTests {

    private static let fakeClaude = "awk -v f=\"$HOME/received\" '{ print > f; fflush(f) }'"

    private func enqueue(_ box: ClaudeTaskDispatcherTests.Box, id: String, choice: ClaudeTaskModelChoice) throws {
        var request = ClaudeTaskRequest(prompt: "Actualiza dependencias", session: "proj", window: 0)
        request.modelChoice = choice
        let incoming = box.tasks.appendingPathComponent("incoming")
        try request.prompt.write(to: incoming.appendingPathComponent("\(id).prompt"), atomically: true, encoding: .utf8)
        try request.metaText(directory: box.home.path).write(to: incoming.appendingPathComponent("\(id).meta"), atomically: true, encoding: .utf8)
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" enqueue proyecto \(id)")
    }

    private func writeSettings(_ box: ClaudeTaskDispatcherTests.Box, _ json: String) throws {
        let folder = box.home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    private func waitLong(_ condition: () -> Bool) {
        for _ in 0..<120 where !condition() { Thread.sleep(forTimeInterval: 0.1) }
    }

    @Test func escribeModelYEffortAntesDelEncargoYLosRestaura() throws {
        let box = try ClaudeTaskDispatcherTests.Box(fakeClaude: Self.fakeClaude)
        defer { box.close() }
        try writeSettings(box, "{\n  \"model\": \"sonnet\",\n  \"theme\": \"dark\"\n}\n")

        try enqueue(box, id: "aaa", choice: ClaudeTaskModelChoice(model: .haiku, effort: .low))
        waitLong { box.receivedText.contains("Actualiza dependencias") }
        let lines = box.receivedText.split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(3)) == ["/model haiku", "/effort low", "Actualiza dependencias"])

        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" stop \(box.pane)", input: "{}")
        waitLong { box.receivedText.contains("/effort auto") }
        let after = box.receivedText.split(separator: "\n").map(String.init)
        #expect(Array(after.suffix(2)) == ["/model sonnet", "/effort auto"], "vuelve a lo guardado; sin esfuerzo guardado, auto")
        #expect(try box.list().first?.state == .done)
    }

    @Test func sinModeloNoEscribeNadaYUnAjusteRaroNoSeRestaura() throws {
        let box = try ClaudeTaskDispatcherTests.Box(fakeClaude: Self.fakeClaude)
        defer { box.close() }
        try writeSettings(box, #"{"model":"x;touch /tmp/argos-mal"}"#)

        try enqueue(box, id: "aaa", choice: .default)
        waitLong { box.receivedText.contains("Actualiza dependencias") }
        #expect(box.receivedText == "Actualiza dependencias\n")
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" stop \(box.pane)", input: "{}")

        try enqueue(box, id: "bbb", choice: ClaudeTaskModelChoice(model: .opus))
        waitLong { box.receivedText.components(separatedBy: "Actualiza dependencias").count == 3 }
        #expect(box.receivedText.contains("/model opus\nActualiza dependencias"))
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" stop \(box.pane)", input: "{}")
        Thread.sleep(forTimeInterval: 3.5)
        #expect(!box.receivedText.contains("touch"), "un modelo guardado raro no se escribe en la terminal")
        #expect(!box.receivedText.hasSuffix("/model default\n"), "ni se cambia por el predeterminado")
    }
}
