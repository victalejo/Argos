//
//  PersistentAgentTests.swift
//  ArgosTests
//
//  Agente persistente: comandos del relay (FIFO + log), invocación de claude, reducer
//  con prompts reenviados y la sesión cliente contra el mock. Incluye una prueba que
//  EJECUTA el script de lanzamiento con `sh` y un claude simulado.
//

import Foundation
import Testing
@testable import Argos

@Suite("Agente persistente: comandos")
struct PersistentAgentScriptTests {

    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private let meta = PersistentAgentMeta(
        workingDirectory: "~/proyectos/tienda",
        title: "tienda",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test func validaIDs() {
        #expect(PersistentAgentScript.isValidID(id))
        #expect(!PersistentAgentScript.isValidID("../../etc"))
        #expect(!PersistentAgentScript.isValidID("abc'; rm -rf ~"))
    }

    @Test func lanzaConFIFOEnLecturaEscrituraYLog() throws {
        let command = try PersistentAgentScript.launch(id: id, meta: meta, claudeInvocation: "env claude -p")
        #expect(command.contains("mkfifo in"))
        #expect(command.contains("umask 077"))
        #expect(command.contains("0<>\"$HOME/.config/argos/agents/\(id)\"/in"))
        #expect(command.contains(">>\"$HOME/.config/argos/agents/\(id)\"/out.ndjson"))
        #expect(command.contains("nohup $S sh -c"))
        #expect(command.hasSuffix("cat pid"))
    }

    @Test func enviaEnBase64SinInterpretarElContenido() throws {
        let line = #"{"type":"user","message":{"content":"$(rm -rf ~) `id` 'hola'"}}"#
        let command = PersistentAgentScript.send(id: id, line: line, log: false)
        #expect(!command.contains("rm -rf"))
        let b64 = try #require(command.split(separator: "'").first { Data(base64Encoded: String($0)) != nil })
        let decoded = String(decoding: try #require(Data(base64Encoded: String(b64))), as: UTF8.self)
        #expect(decoded == line + "\n")
        #expect(command.contains("cat > "))
        #expect(command.contains("ARGOS_AGENT_DEAD"))
    }

    @Test func lasRespuestasAPermisosSeAnotanEnElLog() {
        let command = PersistentAgentScript.send(id: id, line: "{}", log: true)
        #expect(command.contains("tee -a \"$HOME/.config/argos/agents/\(id)\"/out.ndjson"))
    }

    @Test func pararYBorrar() {
        #expect(!PersistentAgentScript.stop(id: id, delete: false).contains("rm -rf"))
        #expect(PersistentAgentScript.stop(id: id, delete: true).contains("rm -rf \"$HOME/.config/argos/agents/\(id)\""))
    }

    @Test func parseaElListadoYDescartaBasura() throws {
        let metaB64 = try JSONEncoder.projects.encode(meta).base64EncodedString()
        let older = PersistentAgentMeta(workingDirectory: "/srv", title: "viejo", createdAt: Date(timeIntervalSince1970: 1))
        let olderB64 = try JSONEncoder.projects.encode(older).base64EncodedString()
        let otherID = UUID().uuidString
        let output = """
        \(otherID)|0|10|\(olderB64)
        \(id)|1|2048|\(metaB64)
        no-es-uuid|1|5|\(metaB64)
        \(UUID().uuidString)|1|5|esto-no-es-base64
        """
        let agents = PersistentAgentScript.parseList(output)
        #expect(agents.map(\.id) == [id, otherID]) // más reciente primero
        #expect(agents[0].isAlive && agents[0].logBytes == 2048 && agents[0].meta == meta)
        #expect(!agents[1].isAlive)
    }

    @Test func invocacionPersistenteReenviaLosPrompts() {
        let nueva = ClaudeAgentCommand.persistent(claudePath: "/usr/bin/claude", oauthToken: "tok'en", sessionID: id, resume: false)
        #expect(nueva.hasPrefix("env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN='tok'\\''en' '/usr/bin/claude' -p"))
        #expect(nueva.contains("--replay-user-messages"))
        #expect(nueva.contains("--session-id \(id)"))
        #expect(nueva.contains("--permission-mode default"))
        let reanudar = ClaudeAgentCommand.persistent(claudePath: "/usr/bin/claude", oauthToken: nil, sessionID: id, resume: true)
        #expect(reanudar.contains("--resume \(id)"))
        #expect(!reanudar.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    /// Ejecuta de verdad el lanzador con `sh`: un «claude» simulado responde por cada
    /// línea de la FIFO. Comprueba el log, que sobrevive sin cliente y que se puede parar.
    @Test func elLanzadorFuncionaDeVerdadConSh() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("argos-home-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = home.appendingPathComponent("claude-falso.sh")
        try """
        #!/bin/sh
        while IFS= read -r line; do printf '{"type":"echo","line":%s}\\n' "$line"; done
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let localMeta = PersistentAgentMeta(workingDirectory: home.path, title: "t", createdAt: Date())
        let launch = try PersistentAgentScript.launch(id: id, meta: localMeta, claudeInvocation: ShellQuoting.singleQuoted(fake.path))
        let pid = try shell(launch, home: home).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(pid) != nil)

        _ = try shell(PersistentAgentScript.send(id: id, line: #"{"n":1}"#, log: false), home: home)
        _ = try shell(PersistentAgentScript.send(id: id, line: #"{"n":2}"#, log: true), home: home)
        let agentDir = home.appendingPathComponent(".config/argos/agents/\(id)")
        var log = ""
        for _ in 0..<150 { // hasta 3 s: el proceso de fondo escribe de forma asíncrona
            log = (try? String(contentsOf: agentDir.appendingPathComponent("out.ndjson"), encoding: .utf8)) ?? ""
            if log.contains(#""line":{"n":2}"#) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let errLog = (try? String(contentsOf: agentDir.appendingPathComponent("err.log"), encoding: .utf8)) ?? "-"
        #expect(log.contains(#"{"type":"echo","line":{"n":1}}"#), "log: \(log) err: \(errLog)")
        #expect(log.contains(#"{"type":"echo","line":{"n":2}}"#))
        #expect(log.contains("{\"n\":2}\n")) // la respuesta con log=true queda anotada

        let listed = PersistentAgentScript.parseList(try shell(PersistentAgentScript.list(), home: home))
        #expect(listed.map(\.id) == [id])
        #expect(listed.first?.isAlive == true)

        _ = try shell(PersistentAgentScript.stop(id: id, delete: false), home: home)
        var alive = true
        for _ in 0..<150 where alive {
            alive = PersistentAgentScript.parseList(try shell(PersistentAgentScript.list(), home: home)).first?.isAlive ?? false
            if alive { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(!alive)
        #expect(throws: (any Error).self) {
            try shell(PersistentAgentScript.send(id: id, line: "{}", log: false), home: home)
        }
    }

    @discardableResult
    private func shell(_ command: String, home: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "sh", code: Int(process.terminationStatus))
        }
        return text
    }
}

@Suite("Agente persistente: conversación")
struct PersistentAgentConversationTests {

    @Test func losPromptsReenviadosSonBurbujasDelUsuario() throws {
        var state = AgentConversationState()
        let user = try #require(AgentProtocol.decode(line: #"{"type":"user","message":{"role":"user","content":"hola"}}"#))
        AgentReducer.apply(user, to: &state, echoesUserMessages: true)
        #expect(state.items.map(\.kind) == [.userText("hola")])
        #expect(state.status == .working)

        // Sin reenvío (modo clásico del Mac) el texto de un evento user se ignora.
        var classic = AgentConversationState()
        AgentReducer.apply(user, to: &classic)
        #expect(classic.items.isEmpty)
    }

    @Test func unaRespuestaAnotadaCierraElPermisoAlReleer() throws {
        var state = AgentConversationState()
        let request = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
        AgentReducer.apply(try #require(AgentProtocol.decode(line: request)), to: &state, echoesUserMessages: true)
        #expect(state.pendingPermission?.id == "r1")
        let answer = AgentProtocol.encodePermissionResponse(requestID: "r1", decision: .allow(updatedInput: .object([:])))
        AgentReducer.apply(try #require(AgentProtocol.decode(line: answer)), to: &state, echoesUserMessages: true)
        #expect(state.pendingPermission == nil)
    }

    @MainActor
    @Test func lanzarLocalizaClaudeYEjecutaElLanzador() async throws {
        let mock = MockSSHService()
        mock.agentScriptOutput = { _ in "4242\n" }
        let session = try await PersistentAgentSession.launch(
            service: mock, workingDirectory: "/srv/app", title: "app", oauthToken: nil
        )
        #expect(PersistentAgentScript.isValidID(session.id))
        #expect(session.isAlive)
        let launch = try #require(mock.agentScripts.first)
        #expect(launch.contains("mkfifo in"))
        #expect(launch.contains("--session-id \(session.id)"))
    }

    @MainActor
    @Test func sinClaudeEnElServidorFallaConMensajeClaro() async {
        let mock = MockSSHService()
        mock.claudePath = nil
        await #expect(throws: PersistentAgentError.claudeMissing) {
            _ = try await PersistentAgentSession.launch(service: mock, workingDirectory: "/", title: "x", oauthToken: nil)
        }
    }

    @MainActor
    @Test func engancharReconstruyeLaConversacionDesdeElLog() async throws {
        let mock = MockSSHService()
        mock.agentScript = [
            #"{"type":"system","subtype":"init","session_id":"s"}"#,
            #"{"type":"user","message":{"role":"user","content":"lista archivos"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hay 3."}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Hay 3."}"#,
        ]
        let session = PersistentAgentSession(service: mock, info: Self.info())
        session.attach()
        try await waitUntil { session.state.items.count == 3 }
        #expect(session.state.items.map(\.kind).prefix(2) == [.userText("lista archivos"), .assistantText("Hay 3.")])
        #expect(session.state.status == .idle)
        #expect(mock.lastAgentCommand?.contains("tail -c +1 -F") == true)

        // Reenganchar no duplica: vuelve a construir desde cero.
        session.attach()
        try await waitUntil { session.state.items.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state.items.count == 3)
        session.detach()
    }

    @MainActor
    @Test func enviarYResponderPermisosVanPorLaFIFO() async throws {
        let mock = MockSSHService()
        let session = PersistentAgentSession(service: mock, info: Self.info())
        await session.send("  hola  ")
        #expect(mock.agentScripts.count == 1)
        #expect(mock.agentScripts[0].contains("cat > "))
        #expect(session.state.status == .working)

        await session.send("   ")
        #expect(mock.agentScripts.count == 1) // vacío: no se envía

        let request = AgentPermissionRequest(id: "r9", toolName: "Bash", displayName: nil, input: .object([:]), toolUseID: nil)
        await session.respond(to: request, decision: .deny(message: "no"))
        #expect(mock.agentScripts[1].contains("tee -a"))
    }

    @MainActor
    @Test func siElAgenteMurioLoMarcaComoNoVivo() async {
        let mock = MockSSHService()
        mock.agentScriptOutput = { _ in throw PersistentAgentError.notRunning }
        let session = PersistentAgentSession(service: mock, info: Self.info())
        await session.send("hola")
        #expect(!session.isAlive)
        #expect(session.lastError == PersistentAgentError.notRunning.userMessage)
    }

    private static func info() -> PersistentAgentInfo {
        PersistentAgentInfo(
            id: "6a55640d-ac70-41ab-8426-6eb72d4fb5eb", isAlive: true, logBytes: 0,
            meta: PersistentAgentMeta(workingDirectory: "/srv", title: "srv", createdAt: Date())
        )
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
}
