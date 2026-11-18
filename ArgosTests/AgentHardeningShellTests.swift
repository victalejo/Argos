//
//  AgentHardeningShellTests.swift
//  ArgosTests
//
//  Ejecuta DE VERDAD con `sh` los scripts remotos nuevos del agente persistente, con un
//  «claude» simulado: hibernación por inactividad, parada con escalado a KILL, envío
//  por stdin de líneas enormes, rotación del log con desplazamientos absolutos, fallo
//  al arrancar y avisos con líneas recortadas.
//

import Foundation
import Testing
@testable import Argos

@Suite("Agente persistente: scripts ejecutados con sh", .serialized)
struct AgentHardeningShellTests {

    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"

    // MARK: - Utilidades

    private struct Run {
        let status: Int32
        let output: String
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("argos-hard-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @discardableResult
    private func sh(_ command: String, home: URL, stdin: Data? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        let input = Pipe()
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// «claude» falso: por cada línea de la FIFO responde. Si contiene `permiso`, pide
    /// un permiso; si no, cierra el turno con un `result`. `ignoreTerm`: no muere con TERM.
    private func fakeClaude(home: URL, ignoreTerm: Bool = false, failing: Bool = false) throws -> String {
        let fake = home.appendingPathComponent("claude-falso.sh")
        let body: String
        if failing {
            body = "#!/bin/sh\necho 'error: unknown option --foo' >&2\nexit 1\n"
        } else {
            body = """
            #!/bin/sh
            \(ignoreTerm ? "trap '' TERM" : "")
            while IFS= read -r line; do
              case "$line" in
                *permiso*) printf '%s\\n' '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}' ;;
                *) printf '{"type":"echo","bytes":%s}\\n' "${#line}"; printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}' ;;
              esac
            done
            """
        }
        try body.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return "\(ShellQuoting.singleQuoted(fake.path)) --session-id \(id)"
    }

    private func meta(_ home: URL) -> PersistentAgentMeta {
        PersistentAgentMeta(workingDirectory: home.path, title: "t", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func agentDir(_ home: URL) -> URL {
        home.appendingPathComponent(".config/argos/agents/\(id)")
    }

    private func listed(_ home: URL) throws -> PersistentAgentInfo? {
        PersistentAgentScript.parseList(try sh(PersistentAgentScript.list(), home: home).output).first
    }

    private func waitUntil(seconds: Double, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try condition()
    }

    private func launch(_ home: URL, invocation: String, hibernation: PersistentAgentHibernation) throws -> Run {
        let command = try PersistentAgentScript.launch(id: id, meta: meta(home), claudeInvocation: invocation, hibernation: hibernation)
        return try sh(command, home: home, stdin: Data("\n".utf8))
    }

    // MARK: - Arranque

    @Test func siClaudeMuereAlArrancarSeDiceElPorque() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let run = try launch(home, invocation: try fakeClaude(home: home, failing: true), hibernation: PersistentAgentHibernation(idleHours: 0))
        #expect(run.status == 6)
        let line = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(throws: PersistentAgentError.launchFailed("error: unknown option --foo\n")) {
            try PersistentAgentSession.parseLaunchReply(line)
        }
    }

    // MARK: - Hibernación

    @Test func elVigilanteHibernaUnAgenteQuietoYSeReanuda() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let invocation = try fakeClaude(home: home)
        let quick = PersistentAgentHibernation(idleSeconds: 1, checkSeconds: 1)
        let run = try launch(home, invocation: invocation, hibernation: quick)
        #expect(Int(run.output.trimmingCharacters(in: .whitespacesAndNewlines)) != nil, "salida: \(run.output)")
        _ = try sh(PersistentAgentScript.send(id: id, line: #"{"n":1}"#), home: home)

        let hibernated = try await waitUntil(seconds: 12) {
            try listed(home).map { !$0.isAlive && $0.meta.isHibernated } ?? false
        }
        #expect(hibernated)
        // `meta.json` sigue siendo JSON válido (lo leen Mac, iPhone y Android).
        let raw = try Data(contentsOf: agentDir(home).appendingPathComponent("meta.json"))
        let decoded = try JSONDecoder.projects.decode(PersistentAgentMeta.self, from: raw)
        #expect(decoded.title == "t" && decoded.hibernatedAt != nil)

        // Reanudar (el cliente quita la marca) lo vuelve a poner en marcha.
        let resumed = try PersistentAgentScript.launch(id: id, meta: meta(home), claudeInvocation: invocation,
                                                       hibernation: PersistentAgentHibernation(idleHours: 0))
        _ = try sh(resumed, home: home, stdin: Data("\n".utf8))
        let info = try #require(try listed(home))
        #expect(info.isAlive && !info.meta.isHibernated)
        _ = try sh(PersistentAgentScript.stop(id: id, delete: true), home: home)
    }

    @Test func noHibernaSiEsperaUnPermiso() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try launch(home, invocation: try fakeClaude(home: home), hibernation: PersistentAgentHibernation(idleSeconds: 1, checkSeconds: 1))
        _ = try sh(PersistentAgentScript.send(id: id, line: #"{"permiso":1}"#), home: home)
        try await Task.sleep(for: .seconds(4))
        #expect(try listed(home)?.isAlive == true)
        _ = try sh(PersistentAgentScript.stop(id: id, delete: true), home: home)
        #expect(!FileManager.default.fileExists(atPath: agentDir(home).path))
    }

    @Test func marcarHibernadoEsIdempotenteYConservaElJSON() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: agentDir(home), withIntermediateDirectories: true)
        var original = meta(home)
        original.permissionMode = "plan"
        try JSONEncoder.projects.encode(original).write(to: agentDir(home).appendingPathComponent("meta.json"))
        let dir = PersistentAgentScript.directory(id)
        _ = try sh(PersistentAgentShell.markHibernated(dir), home: home)
        _ = try sh(PersistentAgentShell.markHibernated(dir), home: home)
        let text = try String(contentsOf: agentDir(home).appendingPathComponent("meta.json"), encoding: .utf8)
        #expect(text.components(separatedBy: "hibernatedAt").count == 2) // una sola vez
        let decoded = try JSONDecoder.projects.decode(PersistentAgentMeta.self, from: Data(text.utf8))
        #expect(decoded.permissionMode == "plan" && decoded.isHibernated)
    }

    // MARK: - Parar

    @Test func pararEscalaAKillYSoloBorraConElProcesoMuerto() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let run = try launch(home, invocation: try fakeClaude(home: home, ignoreTerm: true), hibernation: PersistentAgentHibernation(idleHours: 0))
        let pid = try #require(Int32(run.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0)
        let stop = try sh(PersistentAgentScript.stop(id: id, delete: true, graceSeconds: 1), home: home)
        #expect(stop.status == 0)
        #expect(kill(pid, 0) != 0) // ni con TERM ignorado sobrevive
        #expect(!FileManager.default.fileExists(atPath: agentDir(home).path))
    }

    // MARK: - Envío grande por stdin

    @Test func unaLineaEnormeLlegaPorStdinYSeCompruebaSuLongitud() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try launch(home, invocation: try fakeClaude(home: home), hibernation: PersistentAgentHibernation(idleHours: 0))
        let line = #"{"type":"control_response","response":{"x":""# + String(repeating: "é", count: 90_000) + #""}}"#
        #expect(PersistentAgentScript.needsStdin(line: line))
        #expect(!PersistentAgentScript.needsStdin(line: "{}"))
        let payload = Data((line + "\n").utf8)

        let short = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: payload.count + 1), home: home, stdin: payload)
        #expect(short.output.contains(PersistentAgentScript.shortReply))

        let sent = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: payload.count, answeredRequestID: "r9"), home: home, stdin: payload)
        #expect(sent.status == 0 && sent.output.contains(PersistentAgentScript.sentReply), "salida: \(sent.output)")
        let logURL = agentDir(home).appendingPathComponent("out.ndjson")
        let received = try await waitUntil(seconds: 5) {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").contains(#""bytes":"#)
        }
        #expect(received)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains(#""request_id":"r9""#)) // la marca de respondido
        _ = try sh(PersistentAgentScript.stop(id: id, delete: true), home: home)
        let dead = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: 3), home: home, stdin: Data("{}\n".utf8))
        #expect(dead.output.contains(PersistentAgentScript.deadReply))
    }

    // MARK: - Rotación

    @Test func laRotacionConservaLosDesplazamientosAbsolutos() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":""# + String(repeating: "z", count: 1_000) + "\"}]}}\n"
        let count = PersistentAgentShell.outLogMaxBytes / line.utf8.count + 50
        let original = Data(String(repeating: line, count: count).utf8)
        try original.write(to: dir.appendingPathComponent("out.ndjson"))
        try "150\n".write(to: dir.appendingPathComponent("log.base"), atomically: true, encoding: .utf8)

        _ = try launch(home, invocation: try fakeClaude(home: home), hibernation: PersistentAgentHibernation(idleHours: 0))
        defer { _ = try? sh(PersistentAgentScript.stop(id: id, delete: true), home: home) }

        let rotated = try Data(contentsOf: dir.appendingPathComponent("out.ndjson"))
        let base = try #require(Int(try String(contentsOf: dir.appendingPathComponent("log.base"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(rotated.count <= PersistentAgentShell.outLogKeepBytes)
        #expect(rotated.first == UInt8(ascii: "{")) // empieza en una línea completa
        #expect(base + rotated.count == 150 + original.count) // nada se descuadra
        #expect(try listed(home)?.logBytes == 150 + original.count)

        // El enganche traduce el byte absoluto pedido al local y lo anuncia.
        let header = try sh(PersistentAgentScript.attach(id: id, fromByte: base + 11), home: home).output
            .split(separator: "\n").first.map(String.init) ?? ""
        let parsed = try #require(PersistentAgentScript.parseLogBase(header))
        #expect(parsed.base == base && parsed.from == 11)
        // Lo pedido ya se rotó: desde el principio de lo conservado.
        let old = try sh(PersistentAgentScript.attach(id: id, fromByte: 5), home: home).output
            .split(separator: "\n").first.map(String.init) ?? ""
        #expect(PersistentAgentScript.parseLogBase(old)?.from == 1)
    }

    // MARK: - Avisos

    @Test func unPermisoEnormeSeAvisaAunqueToolNameVengaTarde() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.projects.encode(meta(home)).write(to: dir.appendingPathComponent("meta.json"))
        let big = String(repeating: "x", count: 100_000)
        let late = #"{"type":"control_request","request_id":"r5","request":{"subtype":"can_use_tool","input":{"content":""# + big + #""},"tool_name":"Write"}}"#
        try ("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"a\"}\n" + late + "\n")
            .write(to: dir.appendingPathComponent("out.ndjson"), atomically: true, encoding: .utf8)

        let snapshots = PersistentAgentScript.parseSnapshots(try sh(PersistentAgentScript.snapshots(), home: home).output)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.tail.utf8.count < 2_000)
        #expect(AgentAttention.evaluate(logTail: snapshot.tail) == .needsPermission(tool: "Write"))
    }

    @Test func elInventarioSeEjecutaYSeEntiende() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.projects.encode(meta(home)).write(to: dir.appendingPathComponent("meta.json"))
        try #"{"type":"result","subtype":"success","is_error":false,"result":"a"}"#.appending("\n")
            .write(to: dir.appendingPathComponent("out.ndjson"), atomically: true, encoding: .utf8)
        let run = try sh(ShellQuoting.posixShell(ServerAgentInventory.script()), home: home)
        #expect(run.status == 0)
        let inventory = ServerAgentInventory.parse(run.output)
        let agent = try #require(inventory.agents.first { $0.sessionID == id })
        #expect(!agent.isAlive && !agent.hasPendingPermission)
        #expect((agent.idleSeconds ?? -1) >= 0)
    }
}
