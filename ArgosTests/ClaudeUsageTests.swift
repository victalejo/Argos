//
//  ClaudeUsageTests.swift
//  ArgosTests
//
//  Uso de tokens de Claude: el índice del servidor (script real con sh y dash), la lectura,
//  los precios, los resúmenes por periodo y el modelo de la pantalla.
//

import Testing
import Foundation
@testable import Argos

@Suite("Uso de Claude (lectura, precios y resúmenes)")
struct ClaudeUsageSummaryTests {

    private static func record(_ hour: String, _ project: String, _ model: String, input: Int = 0, output: Int = 0, read: Int = 0, requests: Int = 1) -> ClaudeUsageRecord {
        ClaudeUsageRecord(
            hour: ClaudeUsageRecord.parseHour(hour)!, projectKey: project, model: model,
            tokens: ClaudeTokenCounts(input: input, output: output, cacheRead: read), requests: requests
        )
    }

    @Test func leeLasFilasDelLedgerYElEstado() {
        let output = "status done 1795730400 3 10\n2026-11-26T20\t-Users-v-Desarrollo-Argos\tclaude-opus-5-5\t1\t2\t3\t4\t5\t6\nbasura\n"
        let snapshot = ClaudeUsageSnapshot(output: output)
        #expect(snapshot.status == .done(at: Date(timeIntervalSince1970: 1_795_730_400)))
        #expect(snapshot.records.count == 1)
        let record = snapshot.records[0]
        #expect(record.tokens == ClaudeTokenCounts(input: 1, output: 2, cacheWrite5m: 3, cacheWrite1h: 4, cacheRead: 5))
        #expect(record.requests == 6)
        #expect(ClaudeUsageSnapshot(output: "status \n").status == .never)
        #expect(ClaudeUsageSnapshot(output: "status done 1 0 0\nrunning\n").status == .running(since: Date(timeIntervalSince1970: 1)))
        #expect(ClaudeUsageSnapshot(output: "status running 5\n").status == .running(since: Date(timeIntervalSince1970: 5)))
    }

    @Test func elPrecioUsaElPrefijoMasLargo() throws {
        let opus55 = try #require(ClaudePricing.price(for: "claude-opus-5-5"))
        let opus5 = try #require(ClaudePricing.price(for: "claude-opus-5"))
        #expect(opus55.input == 4)
        #expect(opus5.input == 5)
        #expect(ClaudePricing.price(for: "claude-sonnet-4-6")?.input == 3)
        #expect(ClaudePricing.price(for: "<synthetic>") == nil)
        // 1 M de entrada + 1 M de salida + 1 M leídos de caché en Opus 5.5 = 4 + 20 + 0,2.
        let tokens = ClaudeTokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(opus55.cost(tokens) - 24.2) < 0.0001)
        #expect(ClaudePricing.cost(model: "<synthetic>", tokens: tokens) == 0)
    }

    @Test func resumePorPeriodoProyectoModeloYDia() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ClaudeUsageRecord.parseHour("2026-11-26T20")!
        let records = [
            Self.record("2026-11-26T10", "-Users-v-Desarrollo-Argos", "claude-opus-5-5", output: 1_000_000),
            Self.record("2026-11-25T10", "-Users-v-Desarrollo-tablero", "claude-sonnet-5-5", output: 1_000_000, requests: 3),
            Self.record("2026-11-10T10", "-Users-v-Desarrollo-Argos", "claude-opus-5-5", output: 1_000_000),
        ]
        let names = ["-Users-v-Desarrollo-Argos": "Argos"]
        let today = ClaudeUsageSummary.make(records, range: .today, projectNames: names, now: now, calendar: calendar)
        #expect(today.cost == 20)
        #expect(today.projects.map(\.name) == ["Argos"])

        let week = ClaudeUsageSummary.make(records, range: .week, projectNames: names, now: now, calendar: calendar)
        #expect(week.cost == 30)
        #expect(week.requests == 4)
        #expect(week.projects.map(\.name) == ["Argos", "Desarrollo-tablero"])
        #expect(week.models.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5"])
        #expect(week.days.count == 7)
        #expect(week.days.last?.cost == 20)

        let month = ClaudeUsageSummary.make(records, range: .month, projectNames: names, now: now, calendar: calendar)
        #expect(month.cost == 50)
        #expect(month.days.count == 30)
    }

    @Test func laCarpetaDeClaudeCodeSaleDeLaRuta() {
        #expect(ClaudeUsageProjects.key(forPath: "/Users/victalejo/Desarrollo/OdontoExpress-Pamela") == "-Users-victalejo-Desarrollo-OdontoExpress-Pamela")
        #expect(ClaudeUsageProjects.key(forPath: "/srv/my app/v1.2") == "-srv-my-app-v1-2")
        #expect(ClaudeUsageProjects.key(forPath: "/home/ñu/x") == "-home--u-x")
        #expect(ClaudeUsageProjects.key(forPath: "/p/🚀") == "-p---", "un emoji son dos unidades UTF-16, como en JavaScript")
        #expect(ClaudeUsageProjects.fallbackName("-Users-victalejo-Desarrollo-revib-agent") == "Desarrollo-revib-agent")
        #expect(ClaudeUsageProjects.fallbackName("-root-app") == "app")
        #expect(ClaudeUsageProjects.fallbackName("raro") == "raro")
    }
}

@Suite("Uso de Claude (script del índice)")
struct ClaudeUsageIndexScriptTests {

    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Sandbox {
        let home: URL
        var projects: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
        var usage: URL { home.appendingPathComponent(ClaudeUsageIndex.directoryRelativePath, isDirectory: true) }

        init() throws {
            home = try LocalShell.makeTemporaryDirectory()
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
            let script = home.appendingPathComponent(ClaudeUsageIndex.scriptRelativePath)
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ClaudeUsageIndex.script.write(to: script, atomically: true, encoding: .utf8)
        }

        func append(_ text: String, project: String, session: String) throws {
            let dir = projects.appendingPathComponent(project, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(session).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }

        func run(_ shell: String) throws -> ClaudeUsageSnapshot {
            let index = try LocalShell.run("\(shell) \"$HOME/\(ClaudeUsageIndex.scriptRelativePath)\"", home: home)
            #expect(index.exitCode == 0, "\(index.stderr)")
            return ClaudeUsageSnapshot(output: try LocalShell.run(ClaudeUsageIndex.readCommand, home: home).stdout)
        }

        func remove() { LocalShell.remove(home) }
    }

    /// Una línea de respuesta como las de Claude Code.
    private static func line(_ request: String, output: Int, hour: String = "", model: String = "claude-opus-5-5") -> String {
        let stamp = hour.isEmpty ? ISO8601DateFormatter().string(from: Date()) : hour
        return #"{"parentUuid":"a","message":{"id":"msg_\#(request)","model":"\#(model)","content":[{"type":"text","text":"\"usage\":{ en el texto"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":\#(output),"cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":0},"iterations":[{"input_tokens":999}]}},"requestId":"\#(request)","type":"assistant","timestamp":"\#(stamp)"}"# + "\n"
    }

    @Test("Deduplica, ignora la línea a medias y sigue de forma incremental", arguments: shells)
    func indexesIncrementally(shell: String) throws {
        let box = try Sandbox()
        defer { box.remove() }
        let project = "-home-u-app"
        // La misma respuesta en dos líneas (con la salida parcial en la primera), otra respuesta
        // y una línea de usuario; la misma petición repetida en otra sesión (reanudada).
        try box.append(Self.line("req_1", output: 10) + Self.line("req_1", output: 50) + Self.line("req_2", output: 5)
            + #"{"type":"user","message":{"role":"user","content":"hola"}}"# + "\n", project: project, session: "s1")
        try box.append(Self.line("req_1", output: 50), project: project, session: "s2")
        // Línea a medio escribir al final: no se cuenta todavía.
        try box.append(String(Self.line("req_3", output: 7).dropLast(20)), project: project, session: "s1")

        let first = try box.run(shell)
        guard case .done = first.status else { Issue.record("estado \(first.status)"); return }
        #expect(first.records.reduce(0) { $0 + $1.requests } == 2)
        #expect(first.records.reduce(0) { $0 + $1.tokens.output } == 55)
        #expect(first.records.first?.tokens.cacheWrite1h == 100 * 2)
        #expect(first.records.first?.tokens.input == 4, "no confunde el input de `iterations`")
        #expect(first.records.first?.projectKey == project)

        // Se completa la línea y llega otra respuesta: solo se suma lo nuevo.
        try box.append(String(Self.line("req_3", output: 7).suffix(20)) + Self.line("req_4", output: 1), project: project, session: "s1")
        let second = try box.run(shell)
        #expect(second.records.reduce(0) { $0 + $1.requests } == 4)
        #expect(second.records.reduce(0) { $0 + $1.tokens.output } == 63)

        // Sin cambios, una tercera pasada no suma nada.
        let third = try box.run(shell)
        #expect(third.records.reduce(0) { $0 + $1.requests } == 4)
        #expect(third.records.reduce(0) { $0 + $1.tokens.output } == 63)
        #expect(third.records.count == second.records.count)
    }

    @Test("Descarta lo más viejo que la retención", arguments: shells)
    func dropsOldRecords(shell: String) throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.append(Self.line("req_old", output: 9, hour: "2020-01-01T00:00:00.000Z") + Self.line("req_new", output: 1), project: "-p", session: "s")
        let snapshot = try box.run(shell)
        #expect(snapshot.records.map(\.tokens.output) == [1])
    }

    @Test("Si ya hay un cálculo en marcha, sale sin hacer nada", arguments: shells)
    func respectsLock(shell: String) throws {
        let box = try Sandbox()
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.usage.appendingPathComponent("lock"), withIntermediateDirectories: true)
        let run = try LocalShell.run("\(shell) \"$HOME/\(ClaudeUsageIndex.scriptRelativePath)\"", home: box.home)
        #expect(run.exitCode == 75)
        let snapshot = ClaudeUsageSnapshot(output: try LocalShell.run(ClaudeUsageIndex.readCommand, home: box.home).stdout)
        #expect(snapshot.status == .running(since: nil))
    }
}

@MainActor
@Suite("Uso de Claude (pantalla)")
struct ClaudeUsageModelTests {

    @Test func sinIndiceLoLanzaYEsperaAQueTermine() async {
        let mock = MockSSHService()
        let record = ClaudeUsageRecord(hour: Date(), projectKey: "-p", model: "claude-opus-5-5", tokens: ClaudeTokenCounts(output: 10), requests: 1)
        mock.claudeUsageSnapshots = [
            ClaudeUsageSnapshot(status: .never, records: []),
            ClaudeUsageSnapshot(status: .running(since: nil), records: []),
            ClaudeUsageSnapshot(status: .done(at: Date()), records: [record]),
        ]
        let model = ClaudeUsageModel(service: mock, projects: [], pollInterval: .milliseconds(1))
        await model.load()
        #expect(mock.claudeUsageStarts == 1)
        #expect(model.phase == .ready)
        #expect(model.summary()?.requests == 1)
        #expect(!model.isUpdating)
    }

    @Test func unIndiceRecienteNoSeRecalcula() async {
        let mock = MockSSHService()
        mock.claudeUsageSnapshots = [ClaudeUsageSnapshot(status: .done(at: Date()), records: [])]
        let model = ClaudeUsageModel(service: mock, projects: [], pollInterval: .milliseconds(1))
        await model.load()
        #expect(mock.claudeUsageStarts == 0)
        #expect(model.phase == .ready)
        await model.load(force: true)
        #expect(mock.claudeUsageStarts == 1)
    }
}
