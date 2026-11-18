//
//  AgentHardeningRound3Tests.swift
//  ArgosTests
//
//  Tercera ronda (cierre): la marca de rotación ya no depende de una carrera (el log nuevo
//  EMPIEZA por ella), el envío y la hibernación son atómicos (mismo cerrojo y el envío toca
//  el log). Los scripts se ejecutan DE VERDAD con sh y dash, sin esperas fijas: lo que
//  antes dependía de la carga se reproduce a mano.
//

import Foundation
import Testing
@testable import Argos

@Suite("Agentes: cierre de flecos (rotación, envío e hibernación)", .serialized)
struct AgentHardeningRound3Tests {

    static let shells = ["/bin/sh", "/bin/dash"]
    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private static let patience: Double = 60

    struct Run {
        let status: Int32
        let output: String
    }

    // MARK: - Utilidades

    private func makeHome(shell: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("argos-r3-\(UUID())")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("sh").path, withDestinationPath: shell)
        return home
    }

    private func process(_ command: String, home: URL, shell: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "\(home.path)/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        return process
    }

    @discardableResult
    private func sh(_ command: String, home: URL, shell: String, stdin: Data? = nil) throws -> Run {
        let process = process(command, home: home, shell: shell)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func waitUntil(seconds: Double, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try condition()
    }

    private func agentDir(_ home: URL) -> URL { home.appendingPathComponent(".config/argos/agents/\(id)") }
    private func outURL(_ home: URL) -> URL { agentDir(home).appendingPathComponent("out.ndjson") }

    private func writeMeta(_ home: URL) throws {
        try FileManager.default.createDirectory(at: agentDir(home), withIntermediateDirectories: true)
        let meta = PersistentAgentMeta(workingDirectory: home.path, title: "t", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try JSONEncoder.projects.encode(meta).write(to: agentDir(home).appendingPathComponent("meta.json"))
    }

    /// «claude» que nunca lee la FIFO: el log solo cambia si lo toca el envío.
    private func launchDeafAgent(_ home: URL, shell: String) throws -> Int32 {
        let fake = home.appendingPathComponent("claude-sordo.sh")
        try "#!/bin/sh\nwhile true; do sleep 1; done\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let meta = PersistentAgentMeta(workingDirectory: home.path, title: "t", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let command = try PersistentAgentScript.launch(
            id: id, meta: meta, claudeInvocation: "\(ShellQuoting.singleQuoted(fake.path)) --session-id \(id)",
            hibernation: .init(idleHours: 0)
        )
        let run = try sh(command, home: home, shell: shell, stdin: Data("\n".utf8))
        return try #require(Int32(run.output.trimmingCharacters(in: .whitespacesAndNewlines)), "salida: \(run.output)")
    }

    private func stopAndClean(_ home: URL, shell: String) {
        _ = try? sh(PersistentAgentScript.stop(id: id, delete: true, graceSeconds: 1), home: home, shell: shell)
        try? FileManager.default.removeItem(at: home)
    }

    private func bigLog(_ letter: Character) -> Data {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":""# + String(repeating: letter, count: 1_000) + "\"}]}}\n"
        return Data(String(repeating: line, count: 300).utf8)
    }

    private func header(_ home: URL, shell: String, fromByte: Int) throws -> (base: Int, from: Int)? {
        let output = try sh(PersistentAgentScript.attach(id: id, fromByte: fromByte), home: home, shell: shell).output
        return PersistentAgentScript.parseLogBase(output.split(separator: "\n").first.map(String.init) ?? "")
    }

    // MARK: - Rotación

    /// El log nuevo empieza por la marca, el tamaño absoluto no cambia y lo conservado
    /// sigue en su byte absoluto; el enganche nunca entrega esa marca inicial.
    @Test(arguments: shells) func elLogRotadoEmpiezaPorLaMarcaYElEngancheLaSalta(shell: String) throws {
        let home = try makeHome(shell: shell)
        defer { try? FileManager.default.removeItem(at: home) }
        try writeMeta(home)
        let original = bigLog("z")
        try original.write(to: outURL(home))
        try "150\n".write(to: agentDir(home).appendingPathComponent("log.base"), atomically: true, encoding: .utf8)
        try sh(PersistentAgentShell.rotateOutputLog(PersistentAgentScript.directory(id), maxBytes: 200_000, keepBytes: 100_000),
               home: home, shell: shell)

        let rotated = try Data(contentsOf: outURL(home))
        let mark = PersistentAgentShell.rotatedLineBytes
        #expect(rotated.prefix(mark) == Data((PersistentAgentShell.rotatedLine + "\n").utf8))
        let base = try #require(Int(try String(contentsOf: agentDir(home).appendingPathComponent("log.base"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(base + rotated.count == 150 + original.count) // el tamaño absoluto no cambia
        // Lo conservado (tras la marca) es el FINAL exacto del original, en su byte absoluto.
        let kept = rotated.dropFirst(mark)
        #expect(original.suffix(kept.count) == kept)
        #expect(base + mark == 150 + original.count - kept.count)

        // Desde el principio (reconstruir): sigue tras la marca y anuncia dónde empieza lo conservado.
        let fresh = try #require(try header(home, shell: shell, fromByte: 1))
        #expect(fresh.base == base && fresh.from == mark + 1)
        let firstData = try sh(PersistentAgentScript.attach(id: id), home: home, shell: shell).output
            .split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        #expect(!AgentAttachStreamParser.isRotationMarker(firstData))
        // Pedido justo lo conservado: sin reconstruir (from = byte local tras la marca).
        let exact = try #require(try header(home, shell: shell, fromByte: base + mark + 1))
        #expect(exact.base + exact.from - 1 == base + mark)
        // Al final: no hay nada que reenviar.
        let atEnd = try #require(try header(home, shell: shell, fromByte: base + rotated.count + 1))
        #expect(atEnd.from == rotated.count + 1)
    }

    /// El peor caso de la carrera, reproducido sin depender de la carga: el `tail -F`
    /// NO llegó a leer la marca del archivo viejo y, al ver el nuevo, lo reenvía entero.
    /// El cliente para de contar en la marca inicial y, al reengancharse con sus bytes,
    /// sigue justo donde estaba (sin reconstruir ni duplicar).
    @Test(arguments: shells) func unTailQueNoVioLaMarcaDelViejoNoInflaLosDesplazamientos(shell: String) throws {
        let home = try makeHome(shell: shell)
        defer { try? FileManager.default.removeItem(at: home) }
        try writeMeta(home)
        let original = bigLog("q")
        try original.write(to: outURL(home))
        let firstHeader = try sh(PersistentAgentScript.attach(id: id), home: home, shell: shell).output
            .split(separator: "\n").first.map(String.init) ?? ""
        try sh(PersistentAgentShell.rotateOutputLog(PersistentAgentScript.directory(id), maxBytes: 200_000, keepBytes: 100_000),
               home: home, shell: shell)
        let replaced = try Data(contentsOf: outURL(home))

        // Lo que entrega `tail -F` sin la marca del viejo: cabecera + original + archivo nuevo.
        let stream = Data((firstHeader + "\n").utf8) + original + replaced
        var buffer = NDJSONLineBuffer()
        var parser = AgentAttachStreamParser()
        var counted = 0
        var rotations = 0
        for entry in buffer.appendCountingBytes(Array(stream)) {
            switch parser.classify(text: entry.text) {
            case .data: counted += entry.byteCount
            case .rotated: rotations += 1
            case .noise, .header: break
            }
        }
        #expect(rotations == 1)
        #expect(counted == original.count)

        // Reenganche con lo contado: el servidor sigue en el mismo byte absoluto.
        let next = try #require(try header(home, shell: shell, fromByte: counted + 1))
        #expect(next.base + next.from - 1 == counted)
    }

    // MARK: - Envío frente a hibernación

    /// El vigilante tiene el cerrojo y está hibernando: el envío espera y, al soltarlo,
    /// ve la marca `hibernatedAt` y responde «muerto» (no lo da por enviado).
    @Test(arguments: shells) func elEnvioEsperaAlVigilanteYSiHibernaDiceMuerto(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { stopAndClean(home, shell: shell) }
        _ = try launchDeafAgent(home, shell: shell)
        let lock = home.appendingPathComponent(".config/argos/agents/.\(id).lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)

        let sender = process(PersistentAgentScript.send(id: id, line: #"{"n":1}"#), home: home, shell: shell)
        let errors = Pipe()
        sender.standardError = errors
        sender.standardOutput = FileHandle.nullDevice
        sender.standardInput = FileHandle.nullDevice
        try sender.run()
        // Lo que haría el vigilante con el cerrojo: anotar la hibernación y soltarlo.
        try sh(PersistentAgentShell.markHibernated(PersistentAgentScript.directory(id)), home: home, shell: shell)
        try FileManager.default.removeItem(at: lock)
        #expect(try await waitUntil(seconds: Self.patience) { !sender.isRunning })
        #expect(sender.terminationStatus == 3)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(stderr.contains(PersistentAgentScript.deadReply))
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    /// Lo enviado (aún sin leer por claude) cuenta como actividad: tras el envío, el log
    /// ya no está quieto y ni el vigilante ni «Poner en reposo» lo paran. Vale igual para
    /// el envío por stdin de líneas grandes.
    @Test(arguments: shells) func trasEnviarElAgenteNoSeVeQuieto(shell: String) throws {
        let home = try makeHome(shell: shell)
        defer { stopAndClean(home, shell: shell) }
        _ = try launchDeafAgent(home, shell: shell)
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#
        for useStdin in [false, true] {
            try (result + "\n").write(to: outURL(home), atomically: false, encoding: .utf8)
            try sh("touch -t 202001010000 \(PersistentAgentScript.directory(id))/out.ndjson", home: home, shell: shell)
            if useStdin {
                let payload = Data((String(repeating: "x", count: 8_000) + "\n").utf8)
                let sent = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: payload.count, timeoutSeconds: 5),
                                  home: home, shell: shell, stdin: payload)
                #expect(sent.output.contains(PersistentAgentScript.sentReply), "salida: \(sent.output)")
            } else {
                #expect(try sh(PersistentAgentScript.send(id: id, line: #"{"n":1}"#), home: home, shell: shell).status == 0)
            }
            let modified = try #require(try FileManager.default.attributesOfItem(atPath: outURL(home).path)[.modificationDate] as? Date)
            #expect(Date().timeIntervalSince(modified) < Self.patience)
            let output = try sh(PersistentAgentScript.hibernate(id: id, minIdleSeconds: 600), home: home, shell: shell).output
            #expect(!output.contains(PersistentAgentScript.hibernatedReply))
            #expect(try sh("if \(PersistentAgentScript.aliveCheck(id)); then echo vivo; fi", home: home, shell: shell).output.contains("vivo"))
        }
        // El cerrojo se suelta siempre.
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/argos/agents/.\(id).lock").path))
    }

    // MARK: - Interrumpir

    /// Lo que emite el CLI 2.1.327 al interrumpir a mitad de turno: el cliente no depende de
    /// ningún campo concreto del `result` (ni subtype, ni coste, ni texto) para cerrar el turno.
    @Test func elResultDeUnaInterrupcionCierraElTurnoSinCamposConcretos() {
        let response = #"{"type":"control_response","response":{"subtype":"success","request_id":"argos-interrupt-1","response":{"still_queued":[]}}}"#
        let user = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null}"#
        let result = #"{"type":"result","stop_reason":null,"duration_api_ms":0,"total_cost_usd":0}"#
        var state = AgentConversationState()
        AgentReducer.userSent(text: "tarea", to: &state)
        #expect(state.status == .working)
        for line in [response, user, result] {
            guard let event = AgentProtocol.decode(line: line) else { continue }
            AgentReducer.apply(event, to: &state, echoesUserMessages: true)
        }
        #expect(state.status != .working)
        guard case .result = AgentProtocol.decode(line: result) else {
            Issue.record("un result mínimo debe entenderse")
            return
        }
    }
}
