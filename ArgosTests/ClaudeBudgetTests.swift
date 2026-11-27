//
//  ClaudeBudgetTests.swift
//  ArgosTests
//
//  Presupuesto por proyecto: configuración, cuenta del consumo (ventana de 5 h y día),
//  bloqueos que lee el sondeo y el despachador real con un HOME temporal y un índice de uso
//  simulado (frena al pasar el tope, anota el bloqueo una vez y arranca al liberarse).
//

import Testing
import Foundation
@testable import Argos

/// Filas del índice: hora UTC (`AAAA-MM-DDTHH`) y coste en USD con `claude-opus-4-5`
/// (25 USD por millón de tokens de salida).
enum BudgetLedger {
    static let model = "claude-opus-4-5"

    static func hour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH"
        return formatter.string(from: date)
    }

    static func line(_ date: Date, project: String, usd: Double) -> String {
        let output = Int((usd / 25 * 1_000_000).rounded())
        return "\(hour(date))\t\(project)\t\(model)\t0\t\(output)\t0\t0\t0\t1"
    }

    static func record(_ date: Date, project: String, usd: Double) -> ClaudeUsageRecord {
        ClaudeUsageRecord(ledgerLine: line(date, project: project, usd: usd))!
    }
}

@Suite("Presupuesto por proyecto (lógica)")
struct ClaudeBudgetLogicTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC

    @Test func laConfiguracionSeLeeYSeEscribe() {
        let budget = ClaudeProjectBudget(windowPercent: 20, dailyUSD: 5)
        #expect(budget.configText == "v=1\nwindow_pct=20\ndaily_usd=5.00\n")
        #expect(ClaudeProjectBudget(configText: budget.configText) == budget)
        #expect(ClaudeProjectBudget(configText: "").isEmpty)

        let odd = ClaudeProjectBudget(configText: "v=1\nwindow_pct=300\ndaily_usd=1e9\nfuture=1\n")
        #expect(odd.isEmpty, "fuera de rango o con formato raro se ignora")
        #expect(ClaudeProjectBudget(configText: "window_pct=15\ndaily_usd=2.5").windowPercent == 15)
        #expect(ClaudeProjectBudget(configText: "daily_usd=2.5").dailyUSD == 2.5)
        #expect(ClaudeProjectBudget(configText: "v=2\nwindow_pct=10").isNewerFormat)
        #expect(!budget.isNewerFormat)
    }

    @Test func elConsumoDeLaVentanaEsLaParteDelProyecto() {
        let resets = now.addingTimeInterval(2 * 3600) // la ventana empezó hace 3 h
        let window = ClaudeLimitWindow(kind: ClaudeLimitWindow.fiveHour, usedPercent: 40, resetsAt: resets)
        let records = [
            BudgetLedger.record(now.addingTimeInterval(-3600), project: "a", usd: 3),
            BudgetLedger.record(now.addingTimeInterval(-3600), project: "b", usd: 1),
            // Antes de la ventana: no cuenta.
            BudgetLedger.record(now.addingTimeInterval(-5 * 3600), project: "b", usd: 100),
        ]
        let evaluation = ClaudeBudgetEvaluation.evaluate(
            ClaudeProjectBudget(windowPercent: 20), projectKey: "a", records: records,
            fiveHour: window, now: now, dayStart: now.addingTimeInterval(-8 * 3600)
        )
        guard case .meter(let meter) = evaluation.window else { Issue.record("sin medidor"); return }
        #expect(abs(meter.used - 30) < 0.001, "40 % × 3/4")
        #expect(meter.isExceeded && meter.releasesAt == resets)
        #expect(evaluation.block == .window)
        #expect(evaluation.daily == nil)
    }

    @Test func sinLimitesNoSePuedeEvaluarYUnaVentanaReiniciadaNoFrena() {
        let records = [BudgetLedger.record(now, project: "a", usd: 3)]
        let none = ClaudeBudgetEvaluation.evaluate(
            ClaudeProjectBudget(windowPercent: 20), projectKey: "a", records: records, fiveHour: nil, now: now, dayStart: now
        )
        #expect(none.window == .unavailable && none.block == nil)
        let old = ClaudeLimitWindow(kind: ClaudeLimitWindow.fiveHour, usedPercent: 99, resetsAt: now.addingTimeInterval(-60))
        let reset = ClaudeBudgetEvaluation.evaluate(
            ClaudeProjectBudget(windowPercent: 20), projectKey: "a", records: records, fiveHour: old, now: now, dayStart: now
        )
        #expect(reset.block == nil)
        let notSet = ClaudeBudgetEvaluation.evaluate(
            ClaudeProjectBudget(dailyUSD: 5), projectKey: "a", records: records, fiveHour: old, now: now, dayStart: now
        )
        #expect(notSet.window == .notSet)
    }

    @Test func elConsumoDelDiaEmpiezaALaMedianocheDelServidor() {
        let dayStart = now.addingTimeInterval(-6 * 3600)
        let records = [
            BudgetLedger.record(now.addingTimeInterval(-3600), project: "a", usd: 2),
            BudgetLedger.record(now.addingTimeInterval(-2 * 3600), project: "a", usd: 2),
            BudgetLedger.record(now.addingTimeInterval(-2 * 3600), project: "b", usd: 50),
            BudgetLedger.record(now.addingTimeInterval(-7 * 3600), project: "a", usd: 50),
        ]
        let evaluation = ClaudeBudgetEvaluation.evaluate(
            ClaudeProjectBudget(dailyUSD: 5), projectKey: "a", records: records, fiveHour: nil, now: now, dayStart: dayStart
        )
        let daily = try? #require(evaluation.daily)
        #expect(abs((daily?.used ?? 0) - 4) < 0.001)
        #expect(daily?.releasesAt == dayStart.addingTimeInterval(86_400))
        #expect(evaluation.block == nil)
        let tight = ClaudeBudgetEvaluation.evaluate(
            ClaudeProjectBudget(dailyUSD: 4), projectKey: "a", records: records, fiveHour: nil, now: now, dayStart: dayStart
        )
        #expect(tight.block == .daily)
    }

    @Test func elBloqueoDelSondeoSeLeeYSeExplica() {
        let line = "blocked -Users-v-app v=1 kind=window used=18.40 cap=20 until=1800003600 since=1800000000 "
        let block = try? #require(ClaudeBudgetBlock(pollLine: line))
        #expect(block?.projectKey == "-Users-v-app" && block?.kind == .window && block?.cap == 20)
        #expect(block?.message(now: now).contains("18 % de 20 %") == true)
        #expect(ClaudeBudgetBlock(pollLine: "blocked ../x v=1 kind=window used=1 cap=2 until=3") == nil)
        #expect(ClaudeBudgetBlock(pollLine: "blocked app v=2 kind=window used=1 cap=2 until=3") == nil)
        #expect(ClaudeBudgetBlock(pollLine: "blocked app v=1 kind=raro used=1 cap=2 until=3") == nil)
        let daily = ClaudeBudgetBlock(pollLine: "blocked app v=1 kind=daily used=5.2000 cap=5.00 until=1800003600 since=1")
        #expect(daily?.message(now: now).contains("hoy") == true)

        let output = WorkspacePollCommand.parse(
            "@@argos-poll:budget\n\(line)\n@@argos-poll:end\n", requested: [.budget]
        )
        #expect(output.budgetBlocks?.count == 1)
    }

    @Test func laLecturaDeLaPantallaJuntaConfigBloqueoRelojLimitesYUso() {
        let output = """
            @@config
            v=1
            window_pct=20
            @@blocked
            blocked app v=1 kind=window used=30.00 cap=20 until=1800007200 since=1800000000
            @@clock
            now 1800000000
            daystart 1799971200
            @@limits
            now 1800000000
            1799999990
            {"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1800007200}}}

            @@ledger
            \(BudgetLedger.line(now.addingTimeInterval(-3600), project: "app", usd: 3))
            \(BudgetLedger.line(now.addingTimeInterval(-3600), project: "web", usd: 1))
            @@end
            """
        let reading = ClaudeBudgetReading(output: output, localNow: now)
        #expect(reading.budget.windowPercent == 20)
        #expect(reading.block?.kind == .window)
        #expect(reading.dayStart == Date(timeIntervalSince1970: 1_799_971_200))
        #expect(reading.records.count == 2)
        #expect(reading.evaluation(projectKey: "app", now: now).block == .window)
    }

    @Test func laBandejaEnsenaElProyectoFrenado() {
        let server = UUID()
        let project = Project(name: "App", path: "/Users/v/app")
        let block = ClaudeBudgetBlock(projectKey: "-Users-v-app", kind: .daily, used: 6, cap: 5, until: now.addingTimeInterval(3600))
        let items = AttentionList.build(
            inbox: AttentionInbox(),
            servers: [.init(serverID: server, claude: .empty, projects: [project])],
            budgets: [.init(serverID: server, block: block)],
            now: now
        )
        #expect(items.count == 1)
        #expect(items.first?.kind == .budgetPaused && items.first?.title == "App")
        #expect(items.first?.needsResponse == false)
    }

    @MainActor
    @Test func elViewModelAvisaSoloDeLosBloqueosNuevos() {
        let vm = SessionsViewModel(service: MockSSHService())
        let block = ClaudeBudgetBlock(projectKey: "app", kind: .window, used: 30, cap: 20, until: now.addingTimeInterval(3600))
        #expect(vm.absorbBudgetBlocks([block], now: now) == [block])
        #expect(vm.absorbBudgetBlocks([block], now: now).isEmpty, "el mismo bloqueo no vuelve a avisar")
        let expired = ClaudeBudgetBlock(projectKey: "web", kind: .daily, used: 6, cap: 5, until: now.addingTimeInterval(-1))
        #expect(vm.absorbBudgetBlocks([block, expired], now: now).isEmpty)
        #expect(vm.budgetBlocks == [block])
    }

    @MainActor
    @Test func elModeloGuardaLoQuePideElFormulario() async {
        let mock = MockSSHService()
        mock.budgetReading = ClaudeBudgetReading(output: "@@config\nv=1\ndaily_usd=3\n@@end\n")
        let model = ClaudeBudgetModel(service: mock, projectKey: "app")
        await model.reload()
        #expect(model.dailyEnabled && model.dailyUSD == 3 && !model.windowEnabled)
        #expect(!model.hasChanges)
        model.windowEnabled = true
        model.windowPercent = 25
        #expect(model.canSave)
        await model.save()
        #expect(mock.savedBudgets.first?.0 == ClaudeProjectBudget(windowPercent: 25, dailyUSD: 3))
        #expect(mock.savedBudgets.first?.1 == "app")
    }
}

/// El despachador real (sin tmux: encargos en agente con scripts de mentira).
@Suite("Presupuesto por proyecto (despachador)", .serialized)
struct ClaudeBudgetDispatcherTests {

    final class Box {
        let home: URL
        let tasks: URL
        let budgets: URL
        let usage: URL

        init() throws {
            home = try LocalShell.makeTemporaryDirectory()
            tasks = home.appendingPathComponent(ClaudeTaskScript.directoryRelativePath, isDirectory: true)
            budgets = home.appendingPathComponent(ClaudeBudgetScript.directoryRelativePath, isDirectory: true)
            usage = home.appendingPathComponent(ClaudeUsageIndex.directoryRelativePath, isDirectory: true)
            for dir in [tasks.appendingPathComponent("incoming"), budgets, usage, home.appendingPathComponent(".claude")] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try ClaudeTaskScript.script.write(to: tasks.appendingPathComponent("dispatch.sh"), atomically: true, encoding: .utf8)
        }

        @discardableResult
        func sh(_ command: String) throws -> String { try LocalShell.run(command, home: home).stdout }

        func write(_ text: String, _ relative: String) throws {
            try text.write(to: home.appendingPathComponent(relative), atomically: true, encoding: .utf8)
        }

        /// Límites de la statusline de Argos (con su marcador en settings.json).
        func limits(used: Double, resetsAt: Int) throws {
            try write(#"{"statusLine":{"command":"sh argos-claude-limits"}}"#, ".claude/settings.json")
            try write("\(Int(Date().timeIntervalSince1970))\n{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(used),\"resets_at\":\(resetsAt)}}}\n", ".config/argos/claude-limits.json")
        }

        func ledger(_ lines: [String]) throws {
            try write(lines.joined(separator: "\n") + "\n", ".config/argos/usage/ledger.tsv")
        }

        func enqueue(_ id: String) throws {
            var request = ClaudeTaskRequest(prompt: "Encargo \(id)", session: "proj", window: 0)
            request.target = .agent(id: "11111111-2222-4333-8444-55555555555\(id.count)", worktree: home.path, branch: "argos/encargo-\(id)")
            let incoming = tasks.appendingPathComponent("incoming")
            try "Encargo \(id)".write(to: incoming.appendingPathComponent("\(id).prompt"), atomically: true, encoding: .utf8)
            try request.metaText(directory: home.path).write(to: incoming.appendingPathComponent("\(id).meta"), atomically: true, encoding: .utf8)
            try "read -r token; echo \(id) >> \"$HOME/launched\"\n".write(to: incoming.appendingPathComponent("\(id).launch.sh"), atomically: true, encoding: .utf8)
            try "true\n".write(to: incoming.appendingPathComponent("\(id).send.sh"), atomically: true, encoding: .utf8)
            try sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" enqueue proyecto \(id)")
        }

        func list() throws -> [ClaudeTask] { ClaudeTask.parse(listOutput: try sh(ClaudeTaskScript.listCommand)) }
        func tick() throws { try sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" tick") }
        func blocks() throws -> [ClaudeBudgetBlock] {
            ClaudeBudgetBlock.parse(pollLines: try sh(ClaudeBudgetScript.pollCommand).split(separator: "\n").map(String.init))
        }
        var blockedFile: String {
            (try? String(contentsOf: budgets.appendingPathComponent("proyecto.blocked"), encoding: .utf8)) ?? ""
        }

        func close() { LocalShell.remove(home) }
    }

    @Test func frenaPorLaVentanaAvisaUnaVezYArrancaAlLiberarse() throws {
        let box = try Box()
        defer { box.close() }
        let now = Date()
        let resets = Int(now.timeIntervalSince1970) + 2 * 3600
        try box.limits(used: 40, resetsAt: resets)
        try box.ledger([
            BudgetLedger.line(now.addingTimeInterval(-3600), project: "proyecto", usd: 3),
            BudgetLedger.line(now.addingTimeInterval(-3600), project: "otro", usd: 1),
        ])
        try box.write(ClaudeProjectBudget(windowPercent: 20).configText, ".config/argos/budgets/proyecto")

        try box.enqueue("aaa")
        let waiting = try #require(try box.list().first)
        #expect(waiting.state == .pending && waiting.reason == .budget)
        #expect(!FileManager.default.fileExists(atPath: box.home.appendingPathComponent("launched").path))
        let block = try #require(try box.blocks().first)
        #expect(block.kind == .window && block.cap == 20)
        #expect(abs(block.used - 30) < 0.01, "la misma cuenta que en Swift: 40 % × 3/4")
        #expect(Int(block.until.timeIntervalSince1970) == resets)
        // Lo que lee la pantalla da la misma cuenta.
        let reading = ClaudeBudgetReading(output: try box.sh(ClaudeBudgetScript.readCommand(projectKey: "proyecto")))
        #expect(reading.budget.windowPercent == 20 && reading.block?.kind == .window && reading.records.count == 2)
        guard case .meter(let meter) = reading.evaluation(projectKey: "proyecto").window else {
            Issue.record("sin medidor"); return
        }
        #expect(abs(meter.used - block.used) < 0.01)

        // Otra vuelta con el mismo bloqueo: se conserva su inicio (no es un aviso nuevo).
        let first = box.blockedFile
        Thread.sleep(forTimeInterval: 1.1)
        try box.tick()
        #expect(box.blockedFile.components(separatedBy: "since=").last == first.components(separatedBy: "since=").last)
        #expect(try box.list().first?.state == .pending)

        // Nueva ventana (la anterior se reinició): arranca y el bloqueo desaparece.
        try box.limits(used: 2, resetsAt: Int(now.timeIntervalSince1970) - 60)
        try box.tick()
        #expect(try box.list().first?.state == .running)
        #expect(try box.blocks().isEmpty)
    }

    @Test func frenaPorElDiaYUnProyectoSinTopeNoSeFrena() throws {
        let box = try Box()
        defer { box.close() }
        let now = Date()
        try box.ledger([BudgetLedger.line(now, project: "proyecto", usd: 6)])
        try box.write(ClaudeProjectBudget(windowPercent: 50, dailyUSD: 5).configText, ".config/argos/budgets/proyecto")

        // Sin la statusline de límites el tope de ventana no frena; el diario, sí.
        try box.enqueue("aaa")
        #expect(try box.list().first?.reason == .budget)
        let block = try #require(try box.blocks().first)
        #expect(block.kind == .daily && abs(block.used - 6) < 0.01 && block.cap == 5)
        #expect(block.until > now && block.until <= now.addingTimeInterval(86_400 + 60))

        // Sube el tope: se libera en el siguiente tick.
        try box.write(ClaudeProjectBudget(dailyUSD: 10).configText, ".config/argos/budgets/proyecto")
        try box.tick()
        #expect(try box.list().first?.state == .running)
    }
}
