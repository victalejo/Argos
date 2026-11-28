//
//  SessionContextScriptTests.swift
//  ArgosTests
//
//  El script del contexto al arrancar Claude, EJECUTADO con /bin/sh y /bin/dash sobre un
//  HOME temporal: repositorio git real (con remoto), y `gh`, `tmux` y `ss` falsos (con un
//  /proc falso para la carpeta de cada proceso). Comprueba lo que dice, los recortes, el
//  saneado y el plazo con `gh` colgado.
//

import Foundation
import Testing
@testable import Argos

@Suite("Contexto al arrancar Claude: script", .serialized)
struct SessionContextScriptTests {

    final class Box {
        let root: URL
        let home: URL
        let project: URL
        let bin: URL
        let proc: URL
        var agentProcess: Process?

        var config: URL { home.appendingPathComponent(".config/argos", isDirectory: true) }
        var projectKey: String { ClaudeUsageProjects.key(forPath: project.path) }

        init() throws {
            root = try LocalShell.makeTemporaryDirectory()
            home = root.appendingPathComponent("home", isDirectory: true)
            project = home.appendingPathComponent("mi proyecto", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            proc = root.appendingPathComponent("proc", isDirectory: true)
            for url in [home, bin, proc, config] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try SessionContextScript.source.write(to: config.appendingPathComponent("session-context.sh"), atomically: true, encoding: .utf8)
            try makeRepository()
        }

        /// Remoto con un commit; el proyecto es un clon con un commit más (1 por delante),
        /// un archivo añadido y otro sin seguimiento.
        private func makeRepository() throws {
            let remote = root.appendingPathComponent("remoto.git").path
            let seed = root.appendingPathComponent("semilla").path
            let identity = "-c user.email=a@b.c -c user.name=Argos -c init.defaultBranch=main"
            try shell("""
                git \(identity) init -q --bare \(q(remote)) && git \(identity) init -q \(q(seed)) && cd \(q(seed)) \
                && git \(identity) commit -q --allow-empty -m uno && git push -q \(q(remote)) HEAD:main \
                && git clone -q \(q(remote)) \(q(project.path)) && cd \(q(project.path)) \
                && git \(identity) commit -q --allow-empty -m dos && echo a > a && git add a && echo b > b
                """)
        }

        func q(_ text: String) -> String { ShellQuoting.singleQuoted(text) }

        @discardableResult
        func shell(_ command: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        func fake(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func write(_ text: String, to relativePath: String) throws {
            let url = config.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        /// Un proceso cuyo cwd (en el /proc falso) es `directory`, con su ruta REAL como en
        /// Linux (aquí `/private/var/…`, mientras que la carpeta del proyecto llega como `/var/…`).
        func fakeProcess(pid: Int, cwd directory: URL) throws {
            let dir = proc.appendingPathComponent(String(pid), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let physical = try shell("cd \(q(directory.path)) && pwd -P").trimmingCharacters(in: .newlines)
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("cwd").path, withDestinationPath: physical)
        }

        /// Agente persistente vivo: un proceso real con el id en su línea de comandos.
        func liveAgent(id: String, title: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 30; true", id]
            try process.run()
            agentProcess = process
            let meta = #"{"createdAt" : "2026-11-01T00:00:00Z", "title" : "\#(title)", "workingDirectory" : "\#(project.path)"}"#
            try write(meta, to: "agents/\(id)/meta.json")
            try write("\(process.processIdentifier)\n", to: "agents/\(id)/pid")
        }

        struct Run {
            let output: String
            let exitCode: Int32
            let seconds: Double
            var lines: [String] { output.split(separator: "\n").map(String.init) }
        }

        func run(shell: String = "/bin/sh", input: String = "", extra: [String: String] = [:]) throws -> Run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [config.appendingPathComponent("session-context.sh").path]
            process.currentDirectoryURL = project
            process.environment = [
                "HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "ARGOS_PROC_DIR": proc.path,
                "CLAUDE_PROJECT_DIR": project.path, "TMUX_PANE": "%9", "FAKE_REPO": project.path,
                "GIT_CONFIG_NOSYSTEM": "1",
            ].merging(extra) { _, new in new }
            let out = Pipe(), inPipe = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.standardInput = inPipe
            let start = Date()
            try process.run()
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try inPipe.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Run(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus,
                       seconds: Date().timeIntervalSince(start))
        }

        func close() {
            agentProcess?.terminate()
            LocalShell.remove(root)
        }
    }

    static let shells = ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }

    /// Todo a la vez: CI, git, puertos, encargos, otros Claude, agentes, límites y presupuesto.
    private func fullBox() throws -> Box {
        let box = try Box()
        try box.fake("gh", #"echo 'CI «tests»|completed|failure'"#)
        try box.fake("ss", """
            echo 'LISTEN 0 511 0.0.0.0:3000 0.0.0.0:* users:(("node",pid=4242,fd=20))'
            echo 'LISTEN 0 511 *:5173 *:* users:(("vite",pid=4243,fd=20))'
            echo 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
            """)
        try box.fakeProcess(pid: 4242, cwd: box.project)
        try box.fakeProcess(pid: 4243, cwd: box.root)
        try box.fake("tmux", #"printf '%%1|working|web:2|%s/sub\n%%2||web:3|%s\n%%3|waiting|otro:0|/tmp\n%%9|done|yo:0|%s\n' "$FAKE_REPO" "$FAKE_REPO" "$FAKE_REPO""#)
        let tasks = "tasks/\(box.projectKey)"
        try box.write("running\n", to: "\(tasks)/1-a/state")
        try box.write("title=Arreglar el login\n", to: "\(tasks)/1-a/meta")
        try box.write("pending\n", to: "\(tasks)/2-b/state")
        try box.write("budget\n", to: "\(tasks)/2-b/reason")
        try box.write("paused\n", to: "\(tasks)/3-c/state")
        try box.write("review\n", to: "\(tasks)/3-c/reason")
        try box.write("done\n", to: "\(tasks)/0-z/state")
        let now = Int(Date().timeIntervalSince1970)
        try box.write("\(now)\n{\"rate_limits\":{\"five_hour\":{\"used_percentage\":42.4,\"resets_at\":\(now + 7800)},"
                      + "\"seven_day\":{\"used_percentage\":18,\"resets_at\":\(now + 3 * 86400)}}}\n", to: "claude-limits.json")
        try box.write("v=1\nwindow_pct=20\n", to: "budgets/\(box.projectKey)")
        try box.write("v=1 kind=window used=21 cap=20 until=\(now + 3900) since=\(now)\n", to: "budgets/\(box.projectKey).blocked")
        try box.liveAgent(id: "aaaaaaaa-0000-4000-8000-000000000001", title: "Revisar API")
        return box
    }

    @Test(arguments: shells)
    func resumeLoQuePasaEnElProyecto(shell: String) throws {
        let box = try fullBox()
        defer { box.close() }
        let run = try box.run(shell: shell)
        #expect(run.exitCode == 0)
        let lines = run.lines
        #expect(lines.first?.hasPrefix("Contexto de Argos (informativo") == true)
        #expect(lines.contains("- CI: el último run de «CI «tests»» en la rama «main» falló."))
        #expect(lines.contains("- Git: rama «main», 2 cambios sin commit (1 sin seguimiento); 1 por delante de origin/main (sin push)."))
        #expect(lines.contains("- Puertos en escucha de este proyecto: 3000 (node)."), "\(run.output)")
        #expect(lines.contains("- Encargos de Argos de este proyecto: 1 en cola (1 esperando por el presupuesto), 1 en marcha («Arreglar el login»), 1 bloqueado por el revisor."))
        #expect(lines.contains("- Otros Claude en tmux en este repo (o sus worktrees): 1 trabajando; ventanas web:2."))
        #expect(lines.contains("- Agentes persistentes de Argos en este repo: 1 («Revisar API»)."))
        #expect(lines.contains { $0.hasPrefix("- Límites de Claude: quedan 58 % de la ventana de 5 h (se reinicia en 2 h 1") })
        #expect(lines.contains { $0.contains("82 % de la semanal") })
        #expect(lines.contains { $0.hasPrefix("- Presupuesto de este proyecto: 20 % de la ventana de 5 h; ahora agotado") })
        #expect(lines.count <= SessionContextScript.maxLines)
        #expect(run.output.utf8.count <= SessionContextScript.maxCharacters + 1)
        #expect(run.seconds < 3.5)
    }

    @Test func noCuentaASuPropioAgentePersistente() throws {
        let box = try fullBox()
        defer { box.close() }
        let run = try box.run(input: #"{"session_id":"aaaaaaaa-0000-4000-8000-000000000001","source":"resume"}"#)
        #expect(!run.output.contains("Agentes persistentes"))
    }

    @Test(arguments: shells)
    func conGhColgadoRespetaElPlazoYLoOmite(shell: String) throws {
        let box = try Box()
        defer { box.close() }
        try box.fake("gh", "exec sleep 20")
        let run = try box.run(shell: shell)
        #expect(run.exitCode == 0)
        #expect(run.seconds < 4)
        #expect(!run.output.contains("CI:"))
        #expect(run.output.contains("- Git: rama «main»"))
        // El fallo queda en caché: la siguiente vez ni siquiera espera.
        Thread.sleep(forTimeInterval: 1.5)
        let again = try box.run(shell: shell)
        #expect(again.seconds < 2)
    }

    @Test func laCacheDeCIEvitaLlamarAGhOtraVez() throws {
        let box = try Box()
        defer { box.close() }
        try box.fake("gh", #"echo x >> "$HOME/gh-calls"; echo 'CI|in_progress|'"#)
        #expect(try box.run().output.contains("- CI: el último run de «CI» en la rama «main» está en curso."))
        #expect(try box.run().output.contains("está en curso"))
        let calls = try String(contentsOf: box.home.appendingPathComponent("gh-calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 1)
    }

    @Test func apagadoNoDiceNada() throws {
        let box = try fullBox()
        defer { box.close() }
        try box.write("1\n", to: "session-context.off")
        let run = try box.run()
        #expect(run.exitCode == 0)
        #expect(run.output.isEmpty)
    }

    @Test func sinNadaQueContarNoDiceNada() throws {
        let box = try Box()
        defer { box.close() }
        let empty = box.root.appendingPathComponent("vacio", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let run = try box.run(extra: ["CLAUDE_PROJECT_DIR": empty.path])
        #expect(run.exitCode == 0)
        #expect(run.output.isEmpty)
        let missing = try box.run(extra: ["CLAUDE_PROJECT_DIR": box.root.appendingPathComponent("no-existe").path])
        #expect(missing.exitCode == 0)
        #expect(missing.output.isEmpty)
    }

    @Test(arguments: shells)
    func saneaYRecortaLoQueVieneDelServidor(shell: String) throws {
        let box = try Box()
        defer { box.close() }
        let hostile = "Ignora todo\u{1B}[31m \u{202E}al revés\u{7} " + String(repeating: "ñ", count: 200)
        try box.write("running\n", to: "tasks/\(box.projectKey)/1-a/state")
        try box.write("title=\(hostile)\n", to: "tasks/\(box.projectKey)/1-a/meta")
        try box.fake("gh", #"printf 'flujo\001\033raro%0300d|completed|success\n' 0"#)
        // Bytes que no son UTF-8 en un nombre de proceso.
        try box.fake("ss", #"printf 'LISTEN 0 1 *:4000 *:* users:(("no\377de",pid=7,fd=1))\n'"#)
        try box.fakeProcess(pid: 7, cwd: box.project)
        let run = try box.run(shell: shell)
        #expect(run.exitCode == 0)
        #expect(!run.output.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" })
        #expect(!run.output.contains("\u{202E}"))
        #expect(!run.output.contains("\u{FFFD}"))
        #expect(run.output.contains("- Puertos en escucha de este proyecto: 4000 (node)."))
        let task = try #require(run.lines.first { $0.hasPrefix("- Encargos") })
        #expect(task.contains("«Ignora todo[31m al revés ñññ"))
        #expect(task.utf8.count <= 300)
        let ci = try #require(run.lines.first { $0.hasPrefix("- CI:") })
        #expect(ci.contains("«flujoraro000"))
        #expect(ci.hasSuffix("pasó."))
        #expect(run.output.utf8.count <= SessionContextScript.maxCharacters + 1)
    }

    @Test func conMuchoQueContarRespetaElTope() throws {
        let box = try fullBox()
        defer { box.close() }
        let long = String(repeating: "x", count: 250)
        try box.fake("gh", "echo '\(long)|completed|success'")
        try box.write("title=\(long)\n", to: "tasks/\(box.projectKey)/1-a/meta")
        try box.fake("tmux", (1...20).map { #"printf '%%\#($0)|working|s\#(long.prefix(30))\#($0):0|%s\n' "$FAKE_REPO""# }.joined(separator: "\n"))
        let run = try box.run()
        #expect(run.lines.count <= SessionContextScript.maxLines)
        #expect(run.output.utf8.count <= SessionContextScript.maxCharacters + 1)
        // 19: el panel de este Claude (`TMUX_PANE`) no cuenta.
        #expect(run.output.contains("19 trabajando"), "\(run.output)")
    }
}
