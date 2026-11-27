//
//  ClaudeTaskReviewDispatcherTests.swift
//  ArgosTests
//
//  El revisor automático antes del push con el despachador REAL: un HOME temporal, un
//  remoto git local (`remote.git`), el encargo en agente (sin tmux: termina por su sesión)
//  y un `claude` simulado en `~/.local/bin` que aprueba, bloquea, responde JSON roto, se
//  cuelga o no conoce el modelo. Solo debe haber push cuando aprueba (o con «Subir
//  igualmente»).
//

import Testing
import Foundation
@testable import Argos

@Suite("Revisor antes del push (despachador)", .serialized)
struct ClaudeTaskReviewDispatcherTests {

    static let agentID = "11111111-2222-4333-8444-555555555555"

    static let fakeClaude = #"""
        #!/bin/sh
        printf '%s\n' "$*" >> "$HOME/claude-args"
        cat > "$HOME/claude-stdin"
        case "$(cat "$HOME/claude-mode" 2>/dev/null)" in
          approve) echo 'Revisado: {"verdict":"approve","summary":"Todo bien","findings":[{"severity":"low","category":"other","file":"b.txt","line":1,"message":"Un detalle menor"}]} fin' ;;
          block) echo '{"verdict":"block","summary":"Hay un secreto","findings":[{"severity":"critical","category":"secrets","file":"b.txt","line":1,"message":"Un token en el código"}]}' ;;
          sneaky) echo '{"verdict":"approve","summary":"","findings":[{"severity":"high","category":"tests","message":"Borra un test"}]}' ;;
          broken) echo '{"verdict":"approve", "findings": [ {"severity":' ;;
          prose) echo 'Me parece bien, apruebo.' ;;
          hang) exec sleep 30 ;;
          oldcli)
            case "$*" in *claude-sonnet-5-5*) echo "error: unknown model" >&2; exit 1 ;; esac
            echo '{"verdict":"approve","summary":"","findings":[]}' ;;
          *) exit 3 ;;
        esac
        """#

    final class Box {
        let home: URL
        let tasks: URL
        let work: URL
        let env: [String: String]

        init(mode: String, extraEnv: [String: String] = [:]) throws {
            home = try LocalShell.makeTemporaryDirectory()
            tasks = home.appendingPathComponent(ClaudeTaskScript.directoryRelativePath, isDirectory: true)
            work = home.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: tasks.appendingPathComponent("incoming"), withIntermediateDirectories: true)
            try ClaudeTaskScript.script.write(to: tasks.appendingPathComponent("dispatch.sh"), atomically: true, encoding: .utf8)
            let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try ClaudeTaskReviewDispatcherTests.fakeClaude.write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
            // Con dash si lo hay (el `/bin/sh` de los servidores Debian/Ubuntu): `sh` en el PATH.
            let shells = home.appendingPathComponent("shbin", isDirectory: true)
            try FileManager.default.createDirectory(at: shells, withIntermediateDirectories: true)
            if FileManager.default.isExecutableFile(atPath: "/bin/dash") {
                try FileManager.default.createSymbolicLink(
                    at: shells.appendingPathComponent("sh"), withDestinationURL: URL(fileURLWithPath: "/bin/dash")
                )
            }
            env = [
                "HOME": home.path, "PATH": "\(shells.path):/usr/bin:/bin",
                "GIT_AUTHOR_NAME": "Prueba", "GIT_AUTHOR_EMAIL": "p@example.com",
                "GIT_COMMITTER_NAME": "Prueba", "GIT_COMMITTER_EMAIL": "p@example.com",
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            ].merging(extraEnv) { _, new in new }
            try sh("chmod +x \"$HOME/.local/bin/claude\"; printf '%s' \(ShellQuoting.singleQuoted(mode)) > \"$HOME/claude-mode\"")
            try sh("""
                git init -q --bare "$HOME/remote.git" && git init -q "$HOME/work" && cd "$HOME/work" \
                && git symbolic-ref HEAD refs/heads/main && echo uno > a.txt && git add -A && git commit -q -m inicio \
                && git remote add origin "$HOME/remote.git" && git push -q origin main
                """)
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

        func dispatch(_ arguments: String, input: String? = nil) throws {
            try sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" \(arguments)", input: input)
        }

        /// Encola un encargo en agente sobre `work` con commit y push.
        func enqueue(_ id: String, request: ClaudeTaskRequest) throws {
            let incoming = tasks.appendingPathComponent("incoming")
            try request.prompt.write(to: incoming.appendingPathComponent("\(id).prompt"), atomically: true, encoding: .utf8)
            try request.metaText(directory: work.path).write(to: incoming.appendingPathComponent("\(id).meta"), atomically: true, encoding: .utf8)
            try "read -r token\n".write(to: incoming.appendingPathComponent("\(id).launch.sh"), atomically: true, encoding: .utf8)
            try "true\n".write(to: incoming.appendingPathComponent("\(id).send.sh"), atomically: true, encoding: .utf8)
            try dispatch("enqueue proyecto \(id)")
        }

        func enqueueTask(prompt: String = "Añade b.txt con la segunda línea") throws {
            var request = ClaudeTaskRequest(prompt: prompt, session: "proj", window: 0)
            request.target = .agent(id: ClaudeTaskReviewDispatcherTests.agentID, worktree: work.path, branch: "argos/encargo-x")
            request.commit = true
            request.push = true
            try enqueue("aaa", request: request)
        }

        /// Claude «trabaja» (cambia un archivo) y su hook Stop termina el encargo.
        func finish(agent: String = ClaudeTaskReviewDispatcherTests.agentID, file: String = "b.txt") throws {
            try sh("echo dos >> \"$HOME/work/\(file)\"")
            try dispatch("stop ''", input: #"{"session_id":"\#(agent)","hook_event_name":"Stop"}"#)
        }

        func list() throws -> [ClaudeTask] { ClaudeTask.parse(listOutput: try sh(ClaudeTaskScript.listCommand)) }
        func task(_ index: Int = 0) throws -> ClaudeTask? { try list().dropFirst(index).first }

        var remoteMain: String { (try? sh("git --git-dir \"$HOME/remote.git\" rev-parse main"))?.trimmed ?? "" }
        var workHead: String { (try? sh("git -C \"$HOME/work\" rev-parse HEAD"))?.trimmed ?? "" }
        var pushed: Bool { !workHead.isEmpty && remoteMain == workHead }
        func file(_ name: String) -> String { (try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)) ?? "" }

        /// Espera a que el revisor (en segundo plano) termine.
        func waitForReview(seconds: Double = 15) throws {
            try wait(seconds: seconds) {
                guard let task = try self.task(), task.state != .running, task.reason != .reviewing,
                      FileManager.default.fileExists(atPath: home.appendingPathComponent("claude-args").path)
                else { return false }
                // Aprobado (sin motivo): espera también al push.
                return task.reason != nil || pushed
            }
        }

        func wait(seconds: Double = 10, until condition: () throws -> Bool) rethrows {
            let deadline = Date().addingTimeInterval(seconds)
            while try !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }

        func close() { LocalShell.remove(home) }
    }

    @Test func aprobadoHacePushYLeDaElDiffYElEncargo() throws {
        let box = try Box(mode: "approve")
        defer { box.close() }
        try box.enqueueTask()
        try box.finish()
        try box.waitForReview()
        #expect(box.pushed, "aprobado: push a main")
        let task = try #require(try box.task())
        #expect(task.state == .done && task.reason == nil)
        #expect(task.reviewedVerdict == "approve" && task.review == nil, "el informe completo solo viaja si bloquea")
        let input = box.file("claude-stdin")
        #expect(input.contains("Responde SOLO con un objeto JSON"))
        #expect(input.contains("Añade b.txt con la segunda línea"), "lleva el prompt original")
        #expect(input.contains("+dos") && input.contains("b.txt"), "y el diff base..HEAD")
        #expect(!input.contains("RECORTADO"))
        let args = box.file("claude-args")
        #expect(args.contains("-p --model claude-sonnet-5-5"))
        #expect(args.contains("--tools Read,Grep,Glob") && args.contains("--permission-mode dontAsk"))
        #expect(!args.contains("bypassPermissions"))
    }

    @Test func bloqueadoNoHacePushYGuardaElInforme() throws {
        let box = try Box(mode: "block")
        defer { box.close() }
        let before = box.remoteMain
        try box.enqueueTask()
        try box.finish()
        try box.waitForReview()
        #expect(box.remoteMain == before, "bloqueado: sin push")
        #expect(try box.sh("git -C \"$HOME/work\" log -1 --format=%s").contains("Añade b.txt"), "el commit queda en su rama")
        let task = try #require(try box.task())
        #expect(task.state == .paused && task.reason == .review && task.isBlockedByReview)
        let review = try #require(task.review)
        #expect(review.verdict == .block && review.summary == "Hay un secreto")
        #expect(review.findings.first?.severity == .critical && review.findings.first?.location == "b.txt:1")
        #expect(!box.file(".config/argos/tasks/proyecto/000001-aaa/review.md").isEmpty)

        // Lo bloqueado no se reintenta (repetiría el encargo entero) y aparece en el sondeo.
        try box.dispatch("retry proyecto \(task.folder)")
        #expect(try box.task()?.state == .paused)
        let poll = try box.sh(ClaudeTaskReviewScript.pollCommand)
        #expect(ClaudeTaskReviewBlock.parse(lines: poll.split(separator: "\n").map(String.init)).map(\.id) == [task.id])

        // «Subir igualmente»: el push que faltaba.
        try box.dispatch("push-anyway proyecto \(task.folder)")
        box.wait { box.pushed }
        #expect(box.pushed)
        box.wait { (try? box.task()?.reason) == nil }
        #expect(try box.task()?.state == .done)
        #expect(try box.task()?.reason == nil)
        #expect(try box.sh(ClaudeTaskReviewScript.pollCommand).isEmpty, "ya no está en la bandeja")
    }

    @Test func unHallazgoAltoBloqueaAunqueDigaAprobado() throws {
        let box = try Box(mode: "sneaky")
        defer { box.close() }
        let before = box.remoteMain
        try box.enqueueTask()
        try box.finish()
        try box.waitForReview()
        #expect(box.remoteMain == before)
        #expect(try box.task()?.reason == .review)
    }

    @Test(arguments: ["broken", "prose"])
    func unJSONRotoNoEsConcluyenteYNoSube(mode: String) throws {
        let box = try Box(mode: mode)
        defer { box.close() }
        let before = box.remoteMain
        try box.enqueueTask()
        try box.finish()
        try box.waitForReview()
        #expect(box.remoteMain == before, "nunca cuenta como aprobado")
        let task = try #require(try box.task())
        #expect(task.state == .paused && task.reason == .reviewInconclusive && task.isBlockedByReview)
        #expect(task.review?.verdict == .inconclusive && task.review?.cause == "invalid")
    }

    @Test func siSeCuelgaVenceElPlazoYNoSube() throws {
        let box = try Box(mode: "hang", extraEnv: ["ARGOS_REVIEW_SECONDS": "1"])
        defer { box.close() }
        let before = box.remoteMain
        try box.enqueueTask()
        try box.finish()
        try box.waitForReview(seconds: 20)
        #expect(box.remoteMain == before)
        let task = try #require(try box.task())
        #expect(task.reason == .reviewInconclusive && task.review?.cause == "timeout")
        #expect(task.review?.causeText == String(localized: "El revisor no respondió a tiempo."))
    }

    @Test func conUnCLIViejoUsaElAliasSonnet() throws {
        let box = try Box(mode: "oldcli")
        defer { box.close() }
        try box.enqueueTask()
        try box.finish()
        try box.waitForReview()
        #expect(box.pushed)
        let args = box.file("claude-args")
        #expect(args.contains("--model sonnet") && args.contains("--permission-mode plan"))
        #expect(args.contains("--disallowedTools Bash,Edit,Write"))
    }

    @Test func unDiffEnormeSeRecortaYSeDice() throws {
        let box = try Box(mode: "approve", extraEnv: ["ARGOS_REVIEW_MAX_DIFF": "40"])
        defer { box.close() }
        try box.enqueueTask()
        try box.finish()
        try box.waitForReview()
        #expect(box.file("claude-stdin").contains("RECORTADO"))
    }

    @Test func sinPushNoSeRevisa() throws {
        let box = try Box(mode: "block")
        defer { box.close() }
        var request = ClaudeTaskRequest(prompt: "Solo commit", session: "proj", window: 0)
        request.target = .agent(id: Self.agentID, worktree: box.work.path, branch: "argos/encargo-x")
        request.commit = true
        try box.enqueue("aaa", request: request)
        try box.finish()
        box.wait { (try? box.sh("git -C \"$HOME/work\" log -1 --format=%s"))?.contains("Solo commit") ?? false }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(box.file("claude-args").isEmpty, "los que solo hacen commit no pasan por el revisor")
        #expect(try box.task()?.state == .done)
    }

    @Test func elArregloVaALaMismaRamaYVuelveAPasarPorElRevisor() throws {
        let box = try Box(mode: "block")
        defer { box.close() }
        try box.enqueueTask(prompt: "Encargo original de la prueba")
        try box.finish()
        try box.waitForReview()
        let blocked = try #require(try box.task())
        #expect(blocked.isBlockedByReview)

        var fix = try #require(ClaudeTaskReviewFix.request(for: blocked, permissionMode: .acceptEdits))
        guard case .agent(let fixAgent, let worktree, let branch) = fix.target else { Issue.record("no es agente"); return }
        #expect(worktree == box.work.path && branch == "argos/encargo-x" && fix.reuseWorktree)
        #expect(fix.prompt.contains("Un token en el código") && fix.prompt.contains("critical"))
        fix.taskID = "bbb"
        try box.enqueue("bbb", request: fix)
        let tasks = try box.list()
        #expect(tasks.map(\.state) == [.done, .running])
        #expect(tasks[0].reason == .reviewFixing, "el bloqueado sale de la bandeja")
        #expect(try box.sh(ClaudeTaskReviewScript.pollCommand).isEmpty)

        try box.sh("printf approve > \"$HOME/claude-mode\"; rm -f \"$HOME/claude-args\"")
        try box.finish(agent: fixAgent, file: "c.txt")
        box.wait(seconds: 15) { box.pushed }
        #expect(box.pushed, "aprobado el arreglo, sube los dos commits")
        let input = box.file("claude-stdin")
        #expect(input.contains("Encargo original de la prueba") && input.contains("Encargo de arreglo"))
        #expect(input.contains("b.txt") && input.contains("c.txt"))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
