//
//  ClaudeOrphansTests.swift
//  ArgosTests
//
//  Procesos de Claude huérfanos: detección sobre un árbol de procesos simulado, el comando
//  de matar (lo que acepta) y el script real sobre procesos falsos del Mac (un `sleep`
//  que se presenta como `claude`, desenganchado de la sesión de pruebas).
//

import Testing
import Foundation
@testable import Argos

@Suite("Claude huérfanos (detección)")
struct ClaudeOrphanDetectionTests {

    /// Árbol: tmux con un claude en un panel, un agente persistente, un claude bajo sshd
    /// (agente de la app), uno de otro usuario, uno sin huella y dos huérfanos (uno con
    /// MCP y un claude hijo).
    static let survey = """
        @@me 1000
        pane 101
        agent 400
        p 1 0 0 1000 10-00:00:00 ? systemd
        p 100 1 1000 5000 05:00 ? tmux: server
        p 101 100 1000 3000 05:00 pts/1 bash
        p 102 101 1000 800000 04:00 pts/1 claude
        p 110 100 1000 3000 05:00 pts/2 zsh
        p 111 110 1000 700000 01:00 pts/2 /home/u/.local/bin/claude
        p 200 1 1000 900000 1-02:03:04 ? /usr/local/bin/claude
        p 201 200 1000 100000 1-02:03:00 ? node
        p 202 201 1000 50000 1-02:00:00 ? npm exec mcp
        p 203 200 1000 400000 02:00:00 ? claude
        p 300 1 1000 600000 03:00 pts/9 claude
        p 400 1 1000 500000 03:00 ? claude
        p 401 400 1000 100000 03:00 ? node
        p 500 1 0 1000 9-00:00:00 ? sshd
        p 501 500 1000 2000 01:00 ? sshd-session
        p 502 501 1000 600000 01:00 ? claude
        p 600 1 1001 600000 01:00 ? claude
        p 700 1 1000 600000 01:00 ? claude
        p 800 9999 1000 600000 01:00 ? claude
        start 102 Wed Nov 26 10:00:00 2026
        start 111 Wed Nov 26 10:00:00 2026
        start 200 Tue Nov 25 08:00:00 2026
        start 203 Wed Nov 26 08:00:00 2026
        start 300 Wed Nov 26 11:00:00 2026
        start 400 Wed Nov 26 11:00:00 2026
        start 502 Wed Nov 26 11:00:00 2026
        start 600 Wed Nov 26 11:00:00 2026
        start 800 Wed Nov 26 11:00:00 2026
        start 999 rm -rf $HOME
        """

    @Test func soloLosHuerfanosDeVerdad() {
        let survey = ClaudeProcessSurvey.parse(Self.survey)
        #expect(survey.uid == 1000)
        #expect(survey.fingerprints[999] == nil, "huella con caracteres raros")
        let orphans = survey.orphans()
        // 102/111: tmux. 400: agente. 502: sesión SSH. 600: otro usuario. 700: sin huella.
        // 800: su padre no está en la tabla (cadena rota → no se toca). 203: va con 200.
        #expect(orphans.map(\.pid) == [200, 300])
        let first = orphans[0]
        #expect(first.totalRSSKB == 900_000 + 100_000 + 50_000 + 400_000)
        #expect(first.descendants == 3)
        #expect(first.elapsedSeconds == 86_400 + 2 * 3_600 + 3 * 60 + 4)
        #expect(first.tty == nil)
        #expect(first.fingerprint == "Tue Nov 25 08:00:00 2026")
        #expect(orphans[1].tty == "pts/9")
    }

    @Test func ciclosYTablasRarasNoCuelgan() {
        let survey = ClaudeProcessSurvey.parse("""
            @@me 1000
            p 10 11 1000 100 00:10 ? claude
            p 11 10 1000 100 00:10 ? claude
            p x 1 1000 100 00:10 ? claude
            p 12 1 1000 -5 00:10 ? claude
            start 10 Wed Nov 26 10:00:00 2026
            start 11 Wed Nov 26 10:00:00 2026
            """)
        #expect(survey.processes.count == 2)
        #expect(survey.orphans().isEmpty, "un ciclo nunca llega a init: protegido")
        #expect(ClaudeProcessSurvey.parse("p 1 0 0 1 00:01 ? init").orphans().isEmpty, "sin @@me no hay huérfanos")
    }

    @Test func tiempoTranscurrido() {
        #expect(ClaudeProcessSurvey.parseElapsed("05:07") == 307)
        #expect(ClaudeProcessSurvey.parseElapsed("01:02:03") == 3_723)
        #expect(ClaudeProcessSurvey.parseElapsed("2-01:02:03") == 2 * 86_400 + 3_723)
        #expect(ClaudeProcessSurvey.parseElapsed("abc") == nil)
        #expect(ClaudeProcessSurvey.parseElapsed("1:2:3:4") == nil)
        #expect(ClaudeProcessSurvey.parseElapsed("-1:00") == nil)
    }

    @Test func elComandoDeMatarSoloAceptaHuellasLimpias() {
        let command = ClaudeOrphanScript.killCommand([
            (200, "Tue Nov 25 08:00:00 2026"), (1, "Tue Nov 25 08:00:00 2026"), (300, "x'; rm -rf / #"), (301, ""),
        ])
        #expect(command.contains("take 200 'Tue_Nov_25_08:00:00_2026'"))
        #expect(!command.contains("take 1 ") && !command.contains("take 300") && !command.contains("take 301"))
        let many = ClaudeOrphanScript.killCommand((2...40).map { ($0, "Wed Nov 26 10:00:00 2026") })
        #expect(many.components(separatedBy: "\ntake ").count - 1 == ClaudeOrphanScript.maxTargets)
        #expect(ClaudeOrphanScript.parseKill("killed 200\nskipped 300\nstuck 400\nraro 5\nkilled x\n")
                == [200: .killed, 300: .skipped, 400: .stuck])
    }

    @Test func resumenDelCierre() {
        let text = ClaudeOrphansModel.summary([1: .killed, 2: .stuck], requested: [1, 2, 3])
        #expect(text.contains("1") && text.contains("KILL"))
        #expect(ClaudeOrphansModel.summary([:], requested: []).isEmpty)
    }
}

@Suite("Claude huérfanos (modelo)")
@MainActor
struct ClaudeOrphansModelTests {

    @Test func buscaMarcaYCierra() async {
        let service = MockSSHService()
        service.processSurvey = ClaudeProcessSurvey.parse(ClaudeOrphanDetectionTests.survey)
        let model = ClaudeOrphansModel(service: service)
        await model.scan()
        #expect(model.phase == .loaded && model.orphans.map(\.pid) == [200, 300])
        #expect(!model.canKill)
        model.toggle(model.orphans[0])
        #expect(model.canKill && model.selectedRSSKB == 1_450_000)
        await model.killSelected()
        #expect(service.killedOrphans == [200])
        #expect(model.orphans.map(\.pid) == [300], "se vuelve a buscar")
        #expect(model.selection.isEmpty, "lo cerrado sale de la selección")
        #expect(model.notice?.isEmpty == false)
    }
}

/// El script real con procesos falsos (`exec -a claude`), desenganchados (padre = launchd)
/// para que ningún tmux de quien ejecute las pruebas los proteja.
@Suite("Claude huérfanos (script)", .serialized, .timeLimit(.minutes(2)))
struct ClaudeOrphanScriptTests {

    struct Timeout: Error {}

    final class Box {
        let home: URL
        /// Procesos falsos lanzados: se matan (con todo lo que cuelga de ellos) al terminar.
        private var spawned: [Int] = []

        init() throws { home = try LocalShell.makeTemporaryDirectory() }

        deinit {
            for pid in spawned { Self.killTree(pid) }
            LocalShell.remove(home)
        }

        /// Ejecuta `command` con plazo duro. La salida va a un archivo, no a un pipe: la
        /// tabla de procesos de un Mac ocupado pasa de los 64 KB del pipe y `LocalShell`
        /// (que espera a que acabe antes de leer) se quedaría bloqueado para siempre.
        func run(_ command: String, seconds: Double = 30) throws -> String {
            let output = home.appendingPathComponent("out-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.currentDirectoryURL = home
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning {
                Self.killTree(Int(process.processIdentifier))
                process.waitUntilExit()
                throw Timeout()
            }
            return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        }

        /// Arranca `inner` (bash) con nombre `name`, desenganchado; devuelve su PID.
        func spawn(_ name: String, _ inner: String, tag: String) throws -> Int {
            let pidFile = home.appendingPathComponent("\(tag).pid").path
            let launcher = "echo $$ > '\(pidFile)'; exec -a \(name) /bin/bash -c \(ShellQuoting.singleQuoted(inner)) \(tag)"
            let script = "( nohup /bin/bash -c \(ShellQuoting.singleQuoted(launcher)) </dev/null >/dev/null 2>&1 & ); sleep 1"
            _ = try run(script, seconds: 10)
            let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = Int(text) ?? -1
            if pid > 1 { spawned.append(pid) }
            return pid
        }

        func survey() throws -> ClaudeProcessSurvey {
            ClaudeProcessSurvey.parse(try run(ClaudeOrphanScript.listCommand))
        }

        func kill(_ orphans: [ClaudeOrphan]) throws -> [Int: ClaudeOrphanKillOutcome] {
            ClaudeOrphanScript.parseKill(try run(ClaudeOrphanScript.killCommand(orphans.map { ($0.pid, $0.fingerprint) })))
        }

        static func isAlive(_ pid: Int) -> Bool { Darwin.kill(pid_t(pid), 0) == 0 }

        /// KILL a `pid` y a todos sus descendientes (de los hijos hacia arriba).
        static func killTree(_ pid: Int) {
            guard pid > 1 else { return }
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "pid=,ppid="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = FileHandle.nullDevice
            var children: [Int: [Int]] = [:]
            if (try? ps.run()) != nil {
                // Se lee ANTES de esperar: la tabla no cabe en el pipe.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                ps.waitUntilExit()
                for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                    let fields = line.split(separator: " ").compactMap { Int($0) }
                    if fields.count == 2 { children[fields[1], default: []].append(fields[0]) }
                }
            }
            var order: [Int] = []
            var queue = [pid]
            while let next = queue.popLast(), order.count < 1_000 {
                order.append(next)
                queue.append(contentsOf: children[next] ?? [])
            }
            for victim in order.reversed() { _ = Darwin.kill(pid_t(victim), SIGKILL) }
        }
    }

    @Test func detectaYMataUnHuerfanoConSuHijo() throws {
        let box = try Box()
        let pid = try box.spawn("claude", "sleep 30 & wait", tag: "orphan-\(UUID().uuidString.prefix(8))")
        defer { Box.killTree(pid) }
        let orphan = try #require(try box.survey().orphans().first { $0.pid == pid })
        #expect(orphan.descendants == 1, "el sleep hijo")
        let child = try box.survey().processes.first { $0.ppid == pid }?.pid
        // Huella cambiada: no se toca.
        let wrong = ClaudeOrphan(pid: pid, totalRSSKB: 0, descendants: 0, elapsedSeconds: nil, tty: nil,
                                 fingerprint: "Mon Jan  1 00:00:00 2001")
        #expect(try box.kill([wrong]) == [pid: .skipped])
        #expect(Box.isAlive(pid))
        #expect(try box.kill([orphan]) == [pid: .killed])
        #expect(!Box.isAlive(pid))
        if let child { #expect(!Box.isAlive(child), "también su hijo") }
    }

    @Test func siIgnoraTERMLeLlegaKILL() throws {
        let box = try Box()
        let pid = try box.spawn("claude", "trap '' TERM; sleep 30; :", tag: "stubborn-\(UUID().uuidString.prefix(8))")
        defer { Box.killTree(pid) }
        let orphan = try #require(try box.survey().orphans().first { $0.pid == pid })
        #expect(try box.kill([orphan]) == [pid: .killed])
        #expect(!Box.isAlive(pid))
    }

    @Test func nuncaTocaLoQueCuelgaDeTmuxNiAgentes() throws {
        let box = try Box()
        // Un «tmux» con un claude dentro.
        let tmux = try box.spawn("tmux", "( exec -a claude /bin/bash -c 'sleep 30; :' ); :", tag: "pane-\(UUID().uuidString.prefix(8))")
        defer { Box.killTree(tmux) }
        let survey = try box.survey()
        let inPane = try #require(survey.processes.first { $0.ppid == tmux && $0.name == "claude" })
        defer { Box.killTree(inPane.pid) }
        #expect(!survey.orphans().contains { $0.pid == inPane.pid })
        let forced = ClaudeOrphan(pid: inPane.pid, totalRSSKB: 0, descendants: 0, elapsedSeconds: nil, tty: nil,
                                  fingerprint: survey.fingerprints[inPane.pid] ?? "")
        #expect(try box.kill([forced]) == [inPane.pid: .skipped], "el servidor lo vuelve a comprobar")
        #expect(Box.isAlive(inPane.pid))

        // Un agente persistente registrado (su id va en la línea de comandos).
        let id = UUID().uuidString.lowercased()
        let agent = try box.spawn("claude", "sleep 30; :", tag: id)
        defer { Box.killTree(agent) }
        let dir = box.home.appendingPathComponent("\(PersistentAgentScript.rootRelativePath)/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "\(agent)\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        let again = try box.survey()
        #expect(again.agentPIDs.contains(agent))
        #expect(!again.orphans().contains { $0.pid == agent })
        let forcedAgent = ClaudeOrphan(pid: agent, totalRSSKB: 0, descendants: 0, elapsedSeconds: nil, tty: nil,
                                       fingerprint: again.fingerprints[agent] ?? "")
        #expect(try box.kill([forcedAgent]) == [agent: .skipped])
        #expect(Box.isAlive(agent))
    }
}
