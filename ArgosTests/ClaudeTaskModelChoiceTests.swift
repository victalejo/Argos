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
