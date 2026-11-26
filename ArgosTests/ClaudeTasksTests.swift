//
//  ClaudeTasksTests.swift
//  ArgosTests
//
//  Cola de encargos: lectura del listado, lo que se sube al encolar, los hooks que avisan
//  al despachador, el modelo de la pantalla y el despachador real con un tmux aislado.
//

import Testing
import Foundation
@testable import Argos

@Suite("Encargos (lectura y petición)")
struct ClaudeTaskParsingTests {

    @Test func leeElListadoYToleraLoRaro() {
        let output = """
            @@task -Users-v-app/000002-bbb
            state pending
            reason busy
            started\u{20}
            finished\u{20}
            meta v=1
            meta title=Arregla los tests
            meta context=clear
            meta commit=1
            meta window=2
            prompt Arregla los tests que fallen  y súbelo
            @@task -Users-v-app/000001-aaa
            state done
            reason\u{20}
            started 100
            finished 200
            meta title=Primero
            prompt Primero
            @@task ../../etc/000003-x
            state pending
            @@task -Users-v-app/000004-ccc
            state hackeado
            reason quién-sabe
            prompt raro
            """
        let tasks = ClaudeTask.parse(listOutput: output)
        #expect(tasks.map(\.folder) == ["000001-aaa", "000002-bbb", "000004-ccc"], "ordenados y sin rutas raras")
        let second = tasks[1]
        #expect(second.state == .pending)
        #expect(second.reason == .busy)
        #expect(second.title == "Arregla los tests")
        #expect(second.cleanContext && second.commit)
        #expect(second.window == 2)
        #expect(tasks[0].finished == Date(timeIntervalSince1970: 200))
        #expect(tasks[2].state == nil && tasks[2].reason == nil, "estados y motivos desconocidos se toleran")
        #expect(tasks[2].title == "raro")
    }

    @Test func laPeticionGeneraTituloYMetaSinSaltosDeLinea() {
        var request = ClaudeTaskRequest(prompt: "\n  Revisa el login\nY luego los tests", session: "proj", window: 1)
        request.commit = true
        request.reference = "run 42\nmalo"
        #expect(request.title == "Revisa el login")
        let meta = request.metaText(directory: "/srv/app\nx")
        let lines = meta.split(separator: "\n").map(String.init)
        #expect(lines.contains("dir=/srv/app x"))
        #expect(lines.contains("ref=run 42 malo"))
        #expect(lines.contains("commit=1") && lines.contains("context=same") && lines.contains("window=1"))
        let long = ClaudeTaskRequest(prompt: String(repeating: "a", count: 100), session: "s", window: 0)
        #expect(long.title.count == 72)
        #expect(ClaudeTaskRequest.makeID().count == 12)
    }

    @Test func losHooksAvisanAlDespachadorSoloSiExiste() throws {
        let installed = ClaudeHookInstaller.installing(into: [:])
        #expect(ClaudeHookInstaller.isInstalled(in: installed))
        let hooks = try #require(installed["hooks"] as? [String: Any])
        let stop = (hooks["Stop"] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        let commands = stop.compactMap { $0["command"] as? String }
        #expect(commands.contains(ClaudeHookInstaller.dispatchCommand("stop")))
        #expect(ClaudeHookInstaller.dispatchCommand("stop").contains("[ -f \"$HOME/.config/argos/tasks/dispatch.sh\" ]"))
        // Una instalación anterior (sin el despachador) cuenta como desactualizada.
        var old = installed
        var oldHooks = hooks
        oldHooks["StopFailure"] = (hooks["StopFailure"] as? [[String: Any]])?.filter {
            !(($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("dispatch.sh") ?? false } ?? false)
        }
        old["hooks"] = oldHooks
        #expect(!ClaudeHookInstaller.isInstalled(in: old))
        #expect(ClaudeHookInstaller.hasAnyOurs(in: old))
    }
}

@MainActor
@Suite("Encargos (pantalla)")
struct ClaudeTasksModelTests {

    private static let project = Project(name: "App", path: "/Users/v/app")

    @Test func proponeLaVentanaLibreYEncola() async {
        #expect(ClaudeTasksModel.suggestedWindow([0: .working, 2: .done, 3: .done]) == 2)
        #expect(ClaudeTasksModel.suggestedWindow([1: .working]) == 1)
        #expect(ClaudeTasksModel.suggestedWindow([:]) == 0)

        let mock = MockSSHService()
        let model = ClaudeTasksModel(service: mock, project: Self.project, claudeWindows: [1: .done])
        #expect(!model.canAdd)
        model.draft = "  Arregla el build  "
        model.commit = true
        await model.add()
        #expect(mock.enqueuedTasks.count == 1)
        #expect(mock.enqueuedTasks.first?.0.prompt == "Arregla el build")
        #expect(mock.enqueuedTasks.first?.0.window == 1)
        #expect(mock.enqueuedTasks.first?.0.session == Self.project.sessionName)
        #expect(mock.enqueuedTasks.first?.1 == "/Users/v/app")
        #expect(model.draft.isEmpty)
    }

    @Test func soloEnsenaLosEncargosDeSuProyecto() async {
        let mock = MockSSHService()
        let key = ClaudeUsageProjects.key(forPath: Self.project.path)
        mock.tasks = ClaudeTask.parse(listOutput: """
            @@task \(key)/000001-a
            state done
            @@task \(key)/000002-b
            state pending
            @@task -otro/000001-c
            state pending
            """)
        let model = ClaudeTasksModel(service: mock, project: Self.project, claudeWindows: [:])
        await model.reload()
        #expect(model.openTasks.map(\.folder) == ["000002-b"])
        #expect(model.finishedTasks.map(\.folder) == ["000001-a"])
        await model.cancel(model.openTasks[0])
        #expect(mock.taskActions == ["cancel 000002-b"])
    }
}

/// El despachador real contra un tmux propio (`TMUX_TMPDIR` temporal: no toca las sesiones
/// del usuario). En el panel, `awk` hace de Claude: apunta lo que le llega.
enum LocalTmux {
    static let path = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

@Suite("Encargos (despachador con tmux)", .enabled(if: LocalTmux.path != nil), .serialized)
struct ClaudeTaskDispatcherTests {

    private final class Box {
        let home: URL
        let tasks: URL
        let received: URL
        let env: [String: String]
        /// Carpeta corta para el socket: la ruta de un socket Unix no puede pasar de 104 bytes.
        let socketDirectory: URL

        init(fakeClaude: String) throws {
            home = try LocalShell.makeTemporaryDirectory()
            tasks = home.appendingPathComponent(ClaudeTaskScript.directoryRelativePath, isDirectory: true)
            received = home.appendingPathComponent("received")
            try FileManager.default.createDirectory(at: tasks.appendingPathComponent("incoming"), withIntermediateDirectories: true)
            socketDirectory = URL(fileURLWithPath: "/tmp/at-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
            try ClaudeTaskScript.script.write(to: tasks.appendingPathComponent("dispatch.sh"), atomically: true, encoding: .utf8)
            let bin = ((LocalTmux.path ?? "/usr/bin/tmux") as NSString).deletingLastPathComponent
            env = ["HOME": home.path, "TMUX_TMPDIR": socketDirectory.path, "PATH": "\(bin):/usr/bin:/bin"]
            _ = try sh("tmux new-session -d -s proj -x 120 -y 30 \(ShellQuoting.singleQuoted(fakeClaude))")
            Thread.sleep(forTimeInterval: 0.4)
        }

        @discardableResult
        func sh(_ command: String, input: String? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = env
            let out = Pipe(), inPipe = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.standardInput = inPipe
            try process.run()
            if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
            try inPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        func enqueue(_ id: String, prompt: String, window: Int = 0) throws {
            let request = ClaudeTaskRequest(prompt: prompt, session: "proj", window: window)
            let incoming = tasks.appendingPathComponent("incoming")
            try prompt.write(to: incoming.appendingPathComponent("\(id).prompt"), atomically: true, encoding: .utf8)
            try request.metaText(directory: home.path).write(to: incoming.appendingPathComponent("\(id).meta"), atomically: true, encoding: .utf8)
            try sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" enqueue proyecto \(id)")
        }

        func list() throws -> [ClaudeTask] { ClaudeTask.parse(listOutput: try sh(ClaudeTaskScript.listCommand)) }
        var pane: String { (try? sh("tmux list-panes -t proj -F '#{pane_id}'"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        var receivedText: String { (try? String(contentsOf: received, encoding: .utf8)) ?? "" }

        func wait(until condition: () throws -> Bool) rethrows {
            for _ in 0..<60 where try !condition() { Thread.sleep(forTimeInterval: 0.1) }
        }

        func close() {
            _ = try? sh("tmux kill-server")
            LocalShell.remove(home)
            LocalShell.remove(socketDirectory)
        }
    }

    @Test func avanzaAlTerminarYSePausaPorElLimite() throws {
        let box = try Box(fakeClaude: "awk -v f=\"$HOME/received\" '{ print > f; fflush(f) }'")
        defer { box.close() }

        try box.enqueue("aaa", prompt: "Primera tarea\ncon dos líneas")
        try box.enqueue("bbb", prompt: "Segunda tarea")
        try box.wait { box.receivedText.contains("dos líneas") }
        #expect(box.receivedText.contains("Primera tarea"))
        #expect(!box.receivedText.contains("Segunda"), "la segunda espera su turno")
        #expect(try box.list().map(\.state) == [.running, .pending])

        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" stop \(box.pane)", input: "{}")
        try box.wait { box.receivedText.contains("Segunda tarea") }
        #expect(box.receivedText.contains("Segunda tarea"))
        #expect(try box.list().map(\.state) == [.done, .running])

        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" failure \(box.pane)", input: #"{"error":"rate_limit_error"}"#)
        let paused = try box.list()[1]
        #expect(paused.state == .paused)
        #expect(paused.reason == .limit)

        // Cancelar un pausado; reintentar otro.
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" cancel proyecto \(paused.folder)")
        #expect(try box.list()[1].state == .cancelled)
    }

    @Test func noPegaNadaSiClaudeEstaOcupadoONoEstaAbierto() throws {
        let box = try Box(fakeClaude: "awk -v f=\"$HOME/received\" '{ print > f; fflush(f) }'")
        defer { box.close() }
        try box.sh("tmux set-option -p -t \(box.pane) @argos_claude working")
        try box.enqueue("aaa", prompt: "No me pegues")
        Thread.sleep(forTimeInterval: 0.5)
        #expect(box.receivedText.isEmpty)
        #expect(try box.list().first?.reason == .busy)

        // Libre: el siguiente `tick` lo lanza.
        try box.sh("tmux set-option -p -t \(box.pane) @argos_claude done")
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" tick")
        try box.wait { box.receivedText.contains("No me pegues") }
        #expect(try box.list().first?.state == .running)
    }

    @Test func conUnShellEnLaVentanaEsperaAClaude() throws {
        let box = try Box(fakeClaude: "sh")
        defer { box.close() }
        try box.enqueue("aaa", prompt: "echo hola")
        #expect(try box.list().first?.reason == .noClaude)
        #expect(try box.list().first?.state == .pending)
    }

    @Test func unaVentanaQueNoExisteSeDice() throws {
        let box = try Box(fakeClaude: "awk -v f=\"$HOME/received\" '{ print > f; fflush(f) }'")
        defer { box.close() }
        try box.enqueue("aaa", prompt: "x", window: 7)
        #expect(try box.list().first?.reason == .noPane)
    }
}
