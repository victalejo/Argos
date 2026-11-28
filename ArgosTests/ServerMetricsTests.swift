//
//  ServerMetricsTests.swift
//  ArgosTests
//
//  Historial de recursos: parseo de lo que lee la app, reducción para las gráficas, el
//  script de muestreo ejecutado de verdad con un /proc, un `ps` y un journal simulados
//  (el Mac no tiene /proc) y el comando de lectura sobre lo que el script dejó.
//

import Testing
import Foundation
@testable import Argos

@Suite("Historial de recursos (parseo)")
struct ServerMetricsParsingTests {

    @Test func leeLineasEstadoYDescartaBasura() {
        let output = """
            @@installed
            @@timer systemd
            @@now 1700000600
            m 1700000060 16000000 4000000 2000000 1500000 250 52 2 2000000
            m 1700000000 16000000 8000000 0 0 -1 -1 -1 -1
            a 1699999400 16000000 3000000 2000000 1000000 400 310 3 2500000
            m 1700000120 16000000 99999999 0 0 0 0 0 0
            m nan 1 1 1 1 1 1 1 1
            m 1700000180 16000000 4000000 2000000 3000000 5000 52 2 2000000
            o 1700000030 claude
            o 1700000010 cl;a$x(y)
            o 99 viejo
            @@top 200:900000:claude,102:800000:node,xx:1:a,103:-5:b
            """
        let history = ServerMetricsHistory.parse(output)
        #expect(history.isInstalled && !history.lacksProc && !history.isStalled)
        #expect(history.timer == .systemd)
        #expect(history.serverNow == Date(timeIntervalSince1970: 1_700_000_600))
        #expect(history.points.map(\.date.timeIntervalSince1970) == [1_699_999_400, 1_700_000_000, 1_700_000_060, 1_700_000_180],
                "ordenados; fuera la memoria disponible > total y la fecha no numérica")
        let first = history.points[1]
        #expect(first.cpu == nil && first.load == nil && first.claudeProcesses == nil && first.claudeRSSKB == nil)
        #expect(first.swapUsedFraction == nil, "sin swap")
        #expect(first.memoryUsedFraction == 0.5)
        let point = history.points[2]
        #expect(point.cpu == 0.25 && point.load == 0.52 && point.claudeProcesses == 2 && point.claudeRSSKB == 2_000_000)
        #expect(point.swapUsedFraction == 0.25)
        let last = history.points[3]
        #expect(last.cpu == nil, "una CPU de más de 1000 ‰ no vale")
        #expect(last.swapFreeKB == 2_000_000, "swap libre acotada a la total")
        #expect(history.oomMarks.map(\.process) == ["claxy", "claude"], "saneado y sin fechas absurdas")
        #expect(history.topProcesses.map(\.pid) == [200, 102])
    }

    @Test func sinMuestreoNiProcSeDice() {
        let history = ServerMetricsHistory.parse("@@noproc\n@@timer none\n")
        #expect(!history.isInstalled && history.lacksProc && history.points.isEmpty)
        let stalled = ServerMetricsHistory.parse("@@installed\n@@timer none\n")
        #expect(stalled.isStalled)
    }

    @Test func reducirConservaElPeorValor() {
        let points: [ServerMetricsPoint] = (0..<10).map { (index: Int) -> ServerMetricsPoint in
            let seconds: Int = 1_700_000_000 + index * 60
            let available: Int = index == 3 ? 50 : 500
            let swapFree: Int = index == 4 ? 0 : 100
            let cpu: Double = index % 2 == 0 ? 0.2 : 0.4
            let claudeRSS: Int = index == 7 ? 900 : 100
            return ServerMetricsPoint(
                date: Date(timeIntervalSince1970: TimeInterval(seconds)),
                memTotalKB: 1000, memAvailableKB: available,
                swapTotalKB: 100, swapFreeKB: swapFree,
                cpu: cpu, load: Double(index), claudeProcesses: 1,
                claudeRSSKB: claudeRSS
            )
        }
        let reduced = ServerMetricsHistory.downsample(points, maxPoints: 2)
        #expect(reduced.count == 2)
        #expect(reduced[0].memAvailableKB == 50 && reduced[0].swapFreeKB == 0)
        #expect(abs((reduced[0].cpu ?? 0) - 0.28) < 0.0001)
        #expect(reduced[0].load == 4)
        #expect(reduced[1].claudeRSSKB == 900)
        #expect(reduced[0].date == points[0].date)
        #expect(ServerMetricsHistory.downsample(points, maxPoints: 20) == points)
    }

    @Test func rangosYLineaDelDespachador() {
        #expect(ServerMetricsRange.week.usesAggregates && !ServerMetricsRange.day.usesAggregates)
        #expect(ServerMetricsRange.sixHours.seconds == 21_600)
        #expect(ClaudeTaskScript.script.contains(ServerMetricsScript.dispatcherStartLine))
        #expect(ServerMetricsScript.dispatcherStartLine.contains("detach sh \"$HOME/.config/argos/metrics/sample.sh\""))
        #expect(ServerMetricsScript.historyCommand(.week).contains("tenmin.log"))
        #expect(!ServerMetricsScript.historyCommand(.day).contains("tenmin.log"))
    }
}

@Suite("Historial de recursos (modelo)")
@MainActor
struct ServerMetricsModelTests {

    @Test func cargaInstalaYQuita() async {
        let service = MockSSHService()
        let model = ServerMetricsModel(service: service)
        await model.load()
        #expect(model.phase == .loaded && !model.history.isInstalled)
        await model.install()
        #expect(model.history.isInstalled && model.actionError == nil)
        model.range = .week
        await model.load()
        #expect(service.metricsRequests.last == .week)
        await model.uninstall()
        #expect(!model.history.isInstalled)
        #expect(service.metricsActions == ["install", "uninstall"])
    }
}

/// El script de muestreo y el comando de lectura, ejecutados con `sh` sobre un HOME temporal.
@Suite("Historial de recursos (script)", .serialized, .timeLimit(.minutes(2)))
struct ServerMetricsScriptTests {

    final class Box {
        let home: URL
        var metrics: URL { home.appendingPathComponent(ServerMetricsScript.directoryRelativePath) }
        var proc: URL { home.appendingPathComponent("proc") }

        init() throws {
            home = try LocalShell.makeTemporaryDirectory()
            try FileManager.default.createDirectory(at: metrics, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: proc, withIntermediateDirectories: true)
            try ServerMetricsScript.script.write(to: metrics.appendingPathComponent("sample.sh"), atomically: true, encoding: .utf8)
            try """
                MemTotal:       16000000 kB
                MemFree:         1000000 kB
                MemAvailable:    4000000 kB
                SwapTotal:       2000000 kB
                SwapFree:        1500000 kB

                """.write(to: proc.appendingPathComponent("meminfo"), atomically: true, encoding: .utf8)
            try "0.52 0.40 0.30 1/200 999\n".write(to: proc.appendingPathComponent("loadavg"), atomically: true, encoding: .utf8)
            // Un claude en tmux con un hijo node y uno suelto con un MCP de nombre malicioso.
            try """
                    1     0  1000 systemd
                  100     1  5000 tmux: server
                  101   100  3000 bash
                  102   101 800000 claude
                  103   102 200000 node
                  200     1 900000 /usr/local/bin/claude
                  201   200 100000 mcp;rm$(x)
                  300     1  50000 /usr/bin/python3
                  301     1   1000 /usr/bin/python3

                """.write(to: home.appendingPathComponent("ps"), atomically: true, encoding: .utf8)
            try """
                1700000000.1 host kernel: Out of memory: Killed process 4242 (claude) total-vm:1kB
                1700000300.5 host kernel: oom-kill:constraint=CONSTRAINT_NONE
                1700000400.5 host systemd-oomd[12]: Killed /user.slice/user-1000.slice due to memory pressure

                """.write(to: home.appendingPathComponent("journal"), atomically: true, encoding: .utf8)
        }

        deinit { LocalShell.remove(home) }

        /// Una muestra en el instante `now` con los contadores de CPU dados.
        @discardableResult
        func sample(at now: Int, total: Int, idle: Int, script: String? = nil) throws -> LocalShell.Result {
            try "cpu  \(total - idle) 0 0 \(idle) 0 0 0 0 0 0\nbtime 1\n"
                .write(to: proc.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
            let env = "ARGOS_METRICS_PROC='\(proc.path)' ARGOS_METRICS_PS='\(home.path)/ps' ARGOS_METRICS_JOURNAL='\(home.path)/journal' ARGOS_METRICS_NOW=\(now)"
            return try LocalShell.run(script ?? "\(env) sh \"$HOME/\(ServerMetricsScript.scriptRelativePath)\"", home: home)
        }

        func lines(_ file: String) -> [String] {
            let text = (try? String(contentsOf: metrics.appendingPathComponent(file), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }

    @Test func tomaLaMuestraConCPUClaudeYTopSaneado() throws {
        let box = try Box()
        try box.sample(at: 1_700_000_010, total: 1000, idle: 900)
        let result = try box.sample(at: 1_700_000_070, total: 2000, idle: 1400)
        #expect(result.exitCode == 0)
        let lines = box.lines("minute.log")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("m 1700000010 16000000 4000000 2000000 1500000 -1 52 2 2000000 "), "primera: sin CPU")
        // CPU: 1000 ticks de los que 500 ociosos → 500 ‰. Claude: 102+103+200+201.
        #expect(lines[1].hasPrefix("m 1700000070 16000000 4000000 2000000 1500000 500 52 2 2000000 "))
        let top = lines[1].split(separator: " ").last.map(String.init) ?? ""
        #expect(top == "200:900000:claude,102:800000:claude,103:200000:node,201:100000:mcprmx,300:50000:python3")
        #expect(!top.contains("$") && !top.contains(";"))
    }

    @Test func agregaCadaDiezMinutosYRotaSinCrecer() throws {
        let box = try Box()
        var now = 1_700_000_010
        for index in 0..<25 {
            try box.sample(at: now, total: 1000 + index * 100, idle: 900 + index * 50)
            now += 60
        }
        let aggregates = box.lines("tenmin.log")
        #expect(aggregates.count == 2, "dos tramos cerrados: \(aggregates)")
        #expect(aggregates.first?.hasPrefix("a 1699999800 16000000 4000000 2000000 1500000 ") == true)
        // Un día después: lo de minuto viejo se va; el agregado se queda.
        try box.sample(at: now + 86_400, total: 999_999, idle: 1)
        #expect(box.lines("minute.log").count == 1)
        #expect(box.lines("tenmin.log").count >= 2)
        // Ocho días después: tampoco queda agregado viejo.
        try box.sample(at: now + 8 * 86_400, total: 9_999_999, idle: 1)
        #expect(box.lines("tenmin.log").isEmpty, "todo el agregado es de hace más de 7 días")
        #expect(!FileManager.default.fileExists(atPath: box.metrics.appendingPathComponent("lock").path), "suelta el cerrojo")
    }

    @Test func marcasDeOOMSinRepetir() throws {
        let box = try Box()
        try box.sample(at: 1_700_000_500, total: 100, idle: 50)
        try box.sample(at: 1_700_000_560, total: 200, idle: 100)
        #expect(box.lines("oom.log") == ["o 1700000000 claude", "o 1700000400 systemd-oomd"])
    }

    @Test func sinProcOConCerrojoNoEscribe() throws {
        let box = try Box()
        // Sin ARGOS_METRICS_PROC: el /proc del Mac no existe.
        let plain = try box.sample(at: 1_700_000_010, total: 1, idle: 1, script: "sh \"$HOME/\(ServerMetricsScript.scriptRelativePath)\"")
        #expect(plain.exitCode == 0)
        #expect(box.lines("minute.log").isEmpty)
        try FileManager.default.createDirectory(at: box.metrics.appendingPathComponent("lock"), withIntermediateDirectories: false)
        try box.sample(at: 1_700_000_010, total: 1000, idle: 1)
        #expect(box.lines("minute.log").isEmpty, "otra muestra en curso")
    }

    private static func installDispatcher(in box: Box) throws {
        try FileManager.default.createDirectory(
            at: box.home.appendingPathComponent(ClaudeTaskScript.directoryRelativePath), withIntermediateDirectories: true
        )
        try ClaudeTaskScript.script.write(
            to: box.home.appendingPathComponent(ClaudeTaskScript.scriptRelativePath), atomically: true, encoding: .utf8
        )
    }

    @Test func elDespachadorTomaLaMuestraEnCadaTick() throws {
        let box = try Box()
        try Self.installDispatcher(in: box)
        try "cpu  1 0 0 1 0 0 0 0 0 0\n".write(to: box.proc.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
        let env = "ARGOS_METRICS_PROC='\(box.proc.path)' ARGOS_METRICS_PS='\(box.home.path)/ps' ARGOS_METRICS_JOURNAL=/dev/null ARGOS_METRICS_NOW=1700000010"
        let result = try LocalShell.run("\(env) sh \"$HOME/\(ClaudeTaskScript.scriptRelativePath)\" tick", home: box.home)
        #expect(result.exitCode == 0)
        #expect(box.lines("minute.log").count == 1, "el tick espera a la muestra (systemd mataría lo que quede)")
    }

    @Test func unaMuestraColgadaNoFrenaElTick() throws {
        let box = try Box()
        try Self.installDispatcher(in: box)
        // Una muestra que no acaba nunca (un `ps` o un `journalctl` colgados).
        try "sleep 30\n".write(to: box.metrics.appendingPathComponent("sample.sh"), atomically: true, encoding: .utf8)
        let start = Date()
        let result = try LocalShell.run(
            "ARGOS_METRICS_WAIT=1 sh \"$HOME/\(ClaudeTaskScript.scriptRelativePath)\" tick; pkill -f \"$HOME/\(ServerMetricsScript.scriptRelativePath)\"",
            home: box.home
        )
        #expect(result.exitCode == 0)
        #expect(Date().timeIntervalSince(start) < 10, "el tick no espera más de su plazo")
        let script = ClaudeTaskScript.script
        let startLine = try #require(script.range(of: ServerMetricsScript.dispatcherStartLine))
        let expire = try #require(script.range(of: "expire\n", range: startLine.upperBound..<script.endIndex))
        #expect(script[startLine.upperBound..<expire.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "la muestra se lanza en segundo plano antes de expire")
        #expect(script.contains(ServerMetricsScript.dispatcherWaitLine))
    }

    @Test func sinTimeoutElPsRealTienePlazo() throws {
        let box = try Box()
        // Sin ARGOS_METRICS_PS: el `ps` de verdad pasa por `lim`, que en el Mac (sin `timeout`)
        // usa el vigilante propio.
        try "cpu  1 0 0 1 0 0 0 0 0 0\n".write(to: box.proc.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
        let env = "ARGOS_METRICS_PROC='\(box.proc.path)' ARGOS_METRICS_JOURNAL=/dev/null ARGOS_METRICS_NOW=1700000010"
        let result = try LocalShell.run("\(env) sh \"$HOME/\(ServerMetricsScript.scriptRelativePath)\"", home: box.home)
        #expect(result.exitCode == 0)
        let fields = box.lines("minute.log").first?.split(separator: " ") ?? []
        #expect(fields.count == 11, "muestra completa: \(fields)")
        #expect(fields.count == 11 && Int(fields[8]) ?? -1 >= 0, "cuenta los claude del Mac")
    }

    @Test func elComandoDeLecturaDevuelveElRango() throws {
        let box = try Box()
        let now = Int(Date().timeIntervalSince1970) / 600 * 600 - 3_600
        for index in 0..<30 {
            try box.sample(at: now + index * 60, total: 1000 + index * 100, idle: 900 + index * 50)
        }
        let day = try LocalShell.run(ServerMetricsScript.historyCommand(.day), home: box.home)
        let history = ServerMetricsHistory.parse(day.stdout)
        #expect(history.isInstalled)
        #expect(history.lacksProc, "el Mac no tiene /proc")
        #expect(history.points.count == 30)
        #expect(history.topProcesses.count == 5)
        #expect(history.oomMarks.isEmpty, "las marcas simuladas son de 2023")
        let week = ServerMetricsHistory.parse(try LocalShell.run(ServerMetricsScript.historyCommand(.week), home: box.home).stdout)
        let aggregates = box.lines("tenmin.log").count
        #expect(aggregates >= 2)
        #expect(week.points.count < 30 && week.points.count > aggregates, "agregados + los minutos sin agregar")
    }

    /// `launchctl`, `systemctl` y `crontab` falsos (anotan su uso en `$HOME/timer.log`) por
    /// delante en el PATH: el desinstalador nunca llega a los del Mac que ejecuta las pruebas.
    @Test func quitarSoloBorraElHistorialYNuncaElTemporizador() throws {
        let box = try Box()
        let bin = box.home.appendingPathComponent("fakebin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = box.home.appendingPathComponent("timer.log").path
        for tool in ["launchctl", "systemctl", "crontab"] {
            let url = bin.appendingPathComponent(tool)
            try "#!/bin/sh\necho \"\(tool) $*\" >> '\(log)'\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // Lo que depende del tick: cola, presupuestos (sin tareas programadas).
        let tasks = box.home.appendingPathComponent(ClaudeTaskScript.directoryRelativePath)
        let budget = box.home.appendingPathComponent(".config/argos/budgets/x")
        try FileManager.default.createDirectory(at: tasks.appendingPathComponent("proyecto"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: budget, withIntermediateDirectories: true)
        #expect(!ServerMetricsScript.uninstallCommand.contains("launchctl"))
        #expect(!ServerMetricsScript.uninstallCommand.contains("crontab"))
        let result = try LocalShell.run("PATH='\(bin.path):/usr/bin:/bin'; export PATH\n" + ServerMetricsScript.uninstallCommand, home: box.home)
        #expect(result.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: box.metrics.path))
        #expect(FileManager.default.fileExists(atPath: tasks.appendingPathComponent("proyecto").path))
        #expect(FileManager.default.fileExists(atPath: budget.path))
        #expect(((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").isEmpty, "no toca ningún temporizador")
    }
}
