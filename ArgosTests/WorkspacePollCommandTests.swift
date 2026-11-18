//
//  WorkspacePollCommandTests.swift
//  ArgosTests
//
//  El comando agrupado del sondeador: parser con salidas de ejemplo (completas,
//  cortadas, sin tmux…) y ejecución real del script con /bin/sh y /bin/dash contra un
//  `tmux` de mentira y una carpeta de solicitudes de puertos.
//

import Foundation
import Testing
@testable import Argos

@Suite("Sondeo agrupado: comando y parser")
struct WorkspacePollCommandTests {

    private let all = Set(WorkspacePollSection.allCases)

    private func sample(sessionsExit: String = "0 ", truncateAfterSessions: Bool = false) -> String {
        var lines = [
            "@@argos-poll:claude",
            "2|working|%1|0|web",
            "-|done|%2|1|api",
            "@@argos-poll:sessions",
            "web|2|1|1700000000",
            "api|1|0|1700000100",
            "@@argos-poll:sessions-exit \(sessionsExit)",
        ]
        if truncateAfterSessions { return lines.joined(separator: "\n") }
        lines += [
            "@@argos-poll:ports",
            "1700000500",
            "3000\t1700000400\tLa web",
            "@@argos-poll:end",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("Una salida completa rellena las tres secciones")
    func parsesCompleteOutput() throws {
        let output = WorkspacePollCommand.parse(sample(), requested: all)
        let claude = try #require(output.claude)
        #expect(claude.panes.count == 2)
        #expect(claude.activity(forSession: "web") == .working)
        #expect(claude.activity(forSession: "api") == .done)
        guard case .sessions(let sessions) = output.sessions else {
            Issue.record("Se esperaban sesiones: \(String(describing: output.sessions))")
            return
        }
        #expect(sessions.map(\.name) == ["web", "api"])
        #expect(sessions.first?.isAttached == true)
        #expect(output.portRequests == [PortForwardRequest(port: 3000, note: "La web", ageSeconds: 100)])
    }

    @Test("Lo que no llegó completo queda sin dato (se conserva lo último)")
    func truncatedOutputLeavesMissingSections() {
        let output = WorkspacePollCommand.parse(sample(truncateAfterSessions: true), requested: all)
        #expect(output.claude != nil)
        // La sección de sesiones no tiene marcador detrás: no cuenta.
        #expect(output.sessions == nil)
        #expect(output.portRequests == nil)
    }

    @Test("Solo se rellena lo pedido")
    func onlyRequestedSections() {
        let output = WorkspacePollCommand.parse(sample(), requested: [.sessions])
        #expect(output.claude == nil)
        #expect(output.portRequests == nil)
        #expect(output.sessions != nil)
    }

    @Test("Sin servidor tmux: lista vacía; sin tmux: aviso; otro fallo: error con mensaje")
    func classifiesSessionFailures() {
        func sessions(_ exit: String) -> SessionsPollResult? {
            WorkspacePollCommand.parse(sample(sessionsExit: exit), requested: [.sessions]).sessions
        }
        #expect(sessions("1 no server running on /tmp/tmux-1000/default") == .sessions([]))
        #expect(sessions("1 error connecting to /tmp/tmux-1000/default (No such file or directory)") == .sessions([]))
        #expect(sessions("127 sh: 1: tmux: not found") == .tmuxMissing)
        #expect(sessions("1 lost server") == .failed(exitCode: 1, message: "lost server"))
    }

    @Test("Los marcadores no se confunden con datos (tmux no admite ':' en un nombre)")
    func markersCannotBeSessionNames() {
        #expect(throws: SessionNameValidator.ValidationError.self) {
            try SessionNameValidator.validate(WorkspacePollCommand.endMarker)
        }
    }

    @Test("El script reutiliza los comandos de siempre (formato compartido con iPhone y Android)")
    func scriptReusesExistingCommands() {
        let script = WorkspacePollCommand.script(for: all)
        #expect(script.contains(SSHService.claudeActivityCommand))
        #expect(script.contains("tmux list-sessions -F '\(SSHService.sessionFormat)'"))
        #expect(script.contains(PortForwardServerFiles.listRequestsCommand))
        #expect(script.hasSuffix("printf '%s\\n' '\(WorkspacePollCommand.endMarker)'"))
        #expect(!WorkspacePollCommand.script(for: [.sessions]).contains("list-panes"))
    }
}

// MARK: - Ejecución real del script

@Suite("Sondeo agrupado: script ejecutado con sh y dash", .serialized)
struct WorkspacePollScriptTests {

    static let shells = ["/bin/sh", "/bin/dash"]

    /// Carpeta con un `tmux` de mentira (y `sh` = la shell que se prueba) al principio del PATH.
    private struct Sandbox {
        let home: URL
        let bin: URL

        init(shell: String, tmux: String?) throws {
            home = try LocalShell.makeTemporaryDirectory()
            bin = home.appendingPathComponent("bin", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: bin.appendingPathComponent("sh"), withDestinationURL: URL(fileURLWithPath: shell))
            if let tmux {
                let url = bin.appendingPathComponent("tmux")
                try ("#!/bin/sh\n" + tmux).write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }

        func addPortRequest(port: Int, note: String) throws {
            let dir = home.appendingPathComponent(".config/argos/forward-requests", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let created = Int(Date().timeIntervalSince1970)
            try "\(created)\t\(note)\n".write(to: dir.appendingPathComponent("\(port).req"), atomically: true, encoding: .utf8)
        }

        func run(_ shell: String, sections: Set<WorkspacePollSection>) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", RemoteTimeout.wrap(WorkspacePollCommand.script(for: sections))]
            process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
            process.currentDirectoryURL = home
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        func remove() { LocalShell.remove(home) }
    }

    /// tmux con dos sesiones; `web` tiene a Claude trabajando y `api` terminado.
    private static let busyTmux = """
        [ "$1" = -u ] && shift
        case "$1" in
          list-panes) printf 'working|%%1|0|web\\ndone|%%2|1|api\\n' ;;
          capture-pane) printf 'algo\\n  esc to interrupt\\n' ;;
          list-sessions) printf 'web|2|1|1700000000\\napi|1|0|1700000100\\n' ;;
        esac
        """

    @Test("Con sesiones, Claude y una solicitud de puerto", arguments: shells)
    func fullRound(shell: String) throws {
        let sandbox = try Sandbox(shell: shell, tmux: Self.busyTmux)
        defer { sandbox.remove() }
        try sandbox.addPortRequest(port: 5173, note: "Vite")
        let all = Set(WorkspacePollSection.allCases)
        let output = WorkspacePollCommand.parse(try sandbox.run(shell, sections: all), requested: all)

        let claude = try #require(output.claude)
        #expect(claude.activity(forSession: "web") == .working)
        #expect(claude.activity(forSession: "api") == .done)
        #expect(output.sessions == .sessions([
            TmuxSession(name: "web", windowCount: 2, isAttached: true, createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            TmuxSession(name: "api", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
        ]))
        #expect(output.portRequests?.map(\.port) == [5173])
        #expect(output.portRequests?.first?.note == "Vite")
    }

    @Test("Sin servidor tmux: lista vacía y sin solicitudes", arguments: shells)
    func noTmuxServer(shell: String) throws {
        let sandbox = try Sandbox(shell: shell, tmux: """
            echo "no server running on /tmp/tmux-501/default" >&2
            exit 1
            """)
        defer { sandbox.remove() }
        let all = Set(WorkspacePollSection.allCases)
        let output = WorkspacePollCommand.parse(try sandbox.run(shell, sections: all), requested: all)
        #expect(output.claude == .empty)
        #expect(output.sessions == .sessions([]))
        #expect(output.portRequests == [])
    }

    @Test("Sin tmux instalado: se avisa y no se toca la lista", arguments: shells)
    func tmuxNotInstalled(shell: String) throws {
        let sandbox = try Sandbox(shell: shell, tmux: nil)
        defer { sandbox.remove() }
        let output = WorkspacePollCommand.parse(try sandbox.run(shell, sections: [.sessions, .ports]), requested: [.sessions, .ports])
        #expect(output.sessions == .tmuxMissing)
        #expect(output.portRequests == [])
    }
}
