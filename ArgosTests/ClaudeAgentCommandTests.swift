//
//  ClaudeAgentCommandTests.swift
//  ArgosTests
//
//  Verifica la construcción del comando remoto: flags del protocolo, modo de
//  permisos, cwd y, sobre todo, las garantías de seguridad (entrecomillado
//  anti-inyección y neutralización de ANTHROPIC_API_KEY).
//

import Testing
import Foundation
@testable import Argos

struct ClaudeAgentCommandTests {

    @Test("incluye las banderas del protocolo de control")
    func includesProtocolFlags() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/usr/bin/claude",
            workingDirectory: "/home/u/repo",
            sessionID: "11111111-1111-1111-1111-111111111111"
        )
        #expect(command.contains("--input-format stream-json"))
        #expect(command.contains("--output-format stream-json"))
        #expect(command.contains("--permission-prompt-tool stdio"))
        #expect(command.contains("--permission-mode \"$("))
        #expect(command.contains("echo bypassPermissions"))
        #expect(command.contains("--session-id 11111111-1111-1111-1111-111111111111"))
    }

    @Test("neutraliza ANTHROPIC_API_KEY y nunca lleva el token en la línea de comandos")
    func tokenNeverInCommandLine() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/usr/bin/claude",
            workingDirectory: "/repo",
            sessionID: "s"
        )
        #expect(command.contains("env -u ANTHROPIC_API_KEY"))
        #expect(command.contains("IFS= read -r ARGOS_OAUTH"))
        #expect(!command.contains("CLAUDE_CODE_OAUTH_TOKEN='"))
    }

    @Test("entrecomilla cwd y binario contra inyección de shell")
    func quotesAgainstInjection() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/opt/claude",
            workingDirectory: "/tmp/a b; rm -rf ~",
            sessionID: "s"
        )
        // El cwd peligroso queda como un único argumento entrecomillado.
        #expect(command.contains("cd '/tmp/a b; rm -rf ~'"))
        // No debe existir un `rm -rf` fuera de las comillas (no se "escapó" del literal).
        #expect(!command.contains("&& rm -rf"))
    }

    @Test("la línea de token: vacía sin token y sin saltos que se cuelen como prompt")
    func tokenLine() {
        #expect(ClaudeAgentCommand.tokenLine(nil) == Array("\n".utf8))
        #expect(ClaudeAgentCommand.tokenLine("") == Array("\n".utf8))
        #expect(ClaudeAgentCommand.tokenLine(" tok\n") == Array("tok\n".utf8))
        #expect(ClaudeAgentCommand.tokenLine("a\nb\r") == Array("ab\n".utf8))
    }

    @Test("expande ~ a $HOME en vez de dejarlo entre comillas (cd '~' falla)")
    func expandsTilde() {
        #expect(ClaudeAgentCommand.cdTarget(for: "~") == "\"$HOME\"")
        #expect(ClaudeAgentCommand.cdTarget(for: "~/mi proyecto") == "\"$HOME\"/'mi proyecto'")
        #expect(ClaudeAgentCommand.cdTarget(for: "/abs/path") == "'/abs/path'")
        #expect(ClaudeAgentCommand.cdTarget(for: "") == "\"$HOME\"")
    }

    @Test("build con directorio ~ usa $HOME (no cd '~')")
    func buildTilde() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/c", workingDirectory: "~", sessionID: "s"
        )
        #expect(command.contains("cd \"$HOME\" &&"))
        #expect(!command.contains("cd '~'"))
    }

    @Test("el modo de permisos se refleja en la bandera")
    func permissionModeFlag() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/c",
            workingDirectory: "/r",
            sessionID: "s",
            permissionMode: .acceptEdits
        )
        #expect(command.contains("--permission-mode acceptEdits"))
    }

    @Test("El comando anuncia el PID antes del exec (para matarlo sin huérfanos)")
    func announcesPID() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/u/bin/claude", workingDirectory: "~/p", sessionID: "s"
        )
        #expect(command.contains("argos_pid"))
        #expect(command.contains("exec env -u ANTHROPIC_API_KEY"))
        #expect(command.range(of: "argos_pid")!.lowerBound < command.range(of: "exec env")!.lowerBound)
    }

    @Test("Lee el PID anunciado y rechaza líneas ajenas o PIDs inválidos")
    func parsesAnnouncedPID() {
        #expect(ClaudeAgentCommand.announcedPID(in: #"{"type":"argos_pid","pid":361972}"#) == 361972)
        #expect(ClaudeAgentCommand.announcedPID(in: #"{"type":"system","subtype":"init"}"#) == nil)
        #expect(ClaudeAgentCommand.announcedPID(in: #"{"type":"argos_pid","pid":1}"#) == nil)
        #expect(ClaudeAgentCommand.announcedPID(in: #"{"type":"argos_pid","pid":"x"}"#) == nil)
        #expect(ClaudeAgentCommand.announcedPID(in: "texto argos_pid suelto") == nil)
    }
}

/// Ejecuta el comando de verdad con `sh`: un «claude» simulado informa de lo que recibe.
@Suite("Comando del agente en un shell real")
struct ClaudeAgentCommandShellTests {

    private struct Report {
        let lines: [String]
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
    }

    private func run(mode: ClaudeAgentCommand.PermissionMode, stdin: String, remoteUID: String? = nil) throws -> Report {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("argos-agent-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fake = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf 'token=%s\\n' "$CLAUDE_CODE_OAUTH_TOKEN"
        printf 'copia=%s\\n' "$ARGOS_OAUTH"
        printf 'args=%s\\n' "$*"
        IFS= read -r line; printf 'stdin=%s\\n' "$line"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        var path = "/usr/bin:/bin"
        if let remoteUID {
            let id = dir.appendingPathComponent("id")
            try "#!/bin/sh\necho \(remoteUID)\n".write(to: id, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: id.path)
            path = dir.path + ":" + path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ClaudeAgentCommand.build(
            claudePath: fake.path, workingDirectory: dir.path, sessionID: "s", permissionMode: mode
        )]
        process.environment = ["PATH": path, "HOME": dir.path]
        let out = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = input
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Report(lines: text.split(whereSeparator: \.isNewline).map(String.init))
    }

    @Test("el token llega por el entorno, sin copias, y el primer prompt sigue en stdin")
    func tokenViaStdin() throws {
        let report = try run(mode: .default, stdin: "tok-secreto\nhola\n")
        #expect(report.value("token") == "tok-secreto")
        #expect(report.value("copia") == "")
        #expect(report.value("stdin") == "hola")
        #expect(report.value("args")?.contains("tok-secreto") == false)
    }

    @Test("sin token no se define la variable y el prompt no se pierde")
    func noToken() throws {
        let report = try run(mode: .default, stdin: "\nhola\n")
        #expect(report.value("token") == "")
        #expect(report.value("stdin") == "hola")
    }

    @Test("bypass se conserva con un usuario normal")
    func bypassForRegularUser() throws {
        let report = try run(mode: .bypassPermissions, stdin: "\n", remoteUID: "1000")
        #expect(report.value("args")?.contains("--permission-mode bypassPermissions") == true)
    }

    @Test("bypass pasa a preguntar con root, que el CLI rechazaría")
    func bypassFallsBackForRoot() throws {
        let report = try run(mode: .bypassPermissions, stdin: "\n", remoteUID: "0")
        #expect(report.value("args")?.contains("--permission-mode default") == true)
    }

    @Test("un modo explícito no depende del usuario remoto")
    func explicitModeIgnoresUser() throws {
        let report = try run(mode: .plan, stdin: "\n", remoteUID: "0")
        #expect(report.value("args")?.contains("--permission-mode plan") == true)
    }
}
