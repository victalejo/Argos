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
        #expect(command.contains("( umask 077 &&")) // umask solo en un subshell
        #expect(command.contains("0<>\"$HOME/.config/argos/agents/\(id)\"/in"))
        #expect(command.contains(">>\"$HOME/.config/argos/agents/\(id)\"/out.ndjson"))
        #expect(command.contains("nohup $S sh -c"))
        #expect(command.hasPrefix("IFS= read -r ARGOS_OAUTH")) // token por stdin
        #expect(command.contains("ARGOS_AGENT_ALIVE")) // no lanza dos veces
        #expect(command.contains(".\(id).lock"))
    }

    @Test func enviaEnBase64SinInterpretarElContenido() throws {
        let line = #"{"type":"user","message":{"content":"$(rm -rf ~) `id` 'hola'"}}"#
        let command = PersistentAgentScript.send(id: id, line: line)
        #expect(!command.contains("rm -rf"))
        let b64 = try #require(command.split(separator: "'").first { Data(base64Encoded: String($0)) != nil })
        let decoded = String(decoding: try #require(Data(base64Encoded: String(b64))), as: UTF8.self)
        #expect(decoded == line + "\n")
        #expect(command.contains("exec 3<>")) // FIFO en lectura-escritura: nunca se bloquea
        #expect(command.contains("ARGOS_AGENT_DEAD"))
        #expect(command.contains("ps -o args= -p")) // vivo = el pid es DE VERDAD el agente
    }

    @Test func lasRespuestasAPermisosSeAnotanEnElLogDespuesDeEntregarlas() throws {
        let command = PersistentAgentScript.send(id: id, line: "{}", answeredRequestID: "r\"1")
        let parts = command.components(separatedBy: ">&3")
        #expect(parts.count == 2)
        #expect(parts[1].contains(">> \"$HOME/.config/argos/agents/\(id)\"/out.ndjson"))
        let markerB64 = try #require(parts[1].split(separator: "'").first { Data(base64Encoded: String($0)) != nil })
        let marker = try JSONSerialization.jsonObject(with: try #require(Data(base64Encoded: String(markerB64)))) as? [String: String]
        #expect(marker == ["type": PersistentAgentScript.answeredEventType, "request_id": "r\"1"])
    }

    @Test func elTailMuereAlCerrarseElCanal() {
        let command = PersistentAgentScript.attach(id: id)
        #expect(command.contains("tail -c +1 -F"))
        #expect(command.contains("cat > /dev/null; kill $T"))
    }

    @Test func pararYBorrar() {
        #expect(!PersistentAgentScript.stop(id: id, delete: false).contains("rm -rf"))
        #expect(PersistentAgentScript.stop(id: id, delete: false).contains("grep -q -- '\(id)'"))
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

    @Test func invocacionPersistenteReenviaLosPromptsYNoLlevaElToken() {
        let nueva = ClaudeAgentCommand.persistent(claudePath: "/usr/bin/claude", sessionID: id, resume: false)
        #expect(nueva.hasPrefix("env -u ANTHROPIC_API_KEY '/usr/bin/claude' -p"))
        #expect(nueva.contains("--replay-user-messages"))
        #expect(nueva.contains("--session-id \(id)"))
        #expect(nueva.contains("--permission-mode default"))
        #expect(!nueva.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        let reanudar = ClaudeAgentCommand.persistent(claudePath: "/usr/bin/claude", sessionID: id, resume: true)
        #expect(reanudar.contains("--resume \(id)"))
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
        printf '{"type":"token","value":"%s"}\\n' "$CLAUDE_CODE_OAUTH_TOKEN"
        while IFS= read -r line; do printf '{"type":"echo","line":%s}\\n' "$line"; done
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let localMeta = PersistentAgentMeta(workingDirectory: home.path, title: "t", createdAt: Date())
        // Como claude, el proceso lleva el id en su línea de comandos (huella de «vivo»).
        let invocation = "\(ShellQuoting.singleQuoted(fake.path)) --session-id \(id)"
        let launch = try PersistentAgentScript.launch(id: id, meta: localMeta, claudeInvocation: invocation)
        let pid = try shell(launch, home: home, stdin: "tok-secreto\n").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(pid) != nil)
        // Relanzar con el agente vivo no crea otro proceso.
        #expect(try shell(launch, home: home, stdin: "\n").contains("ARGOS_AGENT_ALIVE"))

        _ = try shell(PersistentAgentScript.send(id: id, line: #"{"n":1}"#), home: home)
        _ = try shell(PersistentAgentScript.send(id: id, line: #"{"n":2}"#, answeredRequestID: "r2"), home: home)
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
        #expect(log.contains(#"{"type":"token","value":"tok-secreto"}"#)) // el token llega por stdin
        #expect(log.contains(#""request_id":"r2""#)) // el permiso respondido queda anotado

        // Instantáneas para los avisos: tamaño del log y su final, ejecutadas de verdad.
        let snapshots = PersistentAgentScript.parseSnapshots(try shell(PersistentAgentScript.snapshots(), home: home))
        #expect(snapshots.map(\.id) == [id])
        #expect(snapshots.first?.isAlive == true)
        #expect(snapshots.first?.logBytes == log.utf8.count)
        #expect(snapshots.first?.tail.contains(#""line":{"n":2}"#) == true)

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
            try shell(PersistentAgentScript.send(id: id, line: "{}"), home: home)
        }
    }

    /// Un pid guardado que ya NO es el agente (p. ej. reutilizado tras un reinicio) no se
    /// da por vivo ni se mata.
    @Test func noMataUnProcesoAjenoConElMismoPid() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("argos-home-\(UUID())")
        let dir = home.appendingPathComponent(".config/argos/agents/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ajeno = Process()
        ajeno.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ajeno.arguments = ["30"]
        try ajeno.run()
        defer { ajeno.terminate() }
        try "\(ajeno.processIdentifier)\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        try JSONEncoder.projects.encode(meta).write(to: dir.appendingPathComponent("meta.json"))

        _ = try shell(PersistentAgentScript.stop(id: id, delete: false), home: home)
        #expect(ajeno.isRunning)
        #expect(PersistentAgentScript.parseList(try shell(PersistentAgentScript.list(), home: home)).first?.isAlive == false)
    }

    @discardableResult
    private func shell(_ command: String, home: URL, stdin: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
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

    @Test func laMarcaDeRespondidoCierraElPermisoAlReleer() throws {
        var state = AgentConversationState()
        let request = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#
        AgentReducer.apply(try #require(AgentProtocol.decode(line: request)), to: &state, echoesUserMessages: true)
        #expect(state.pendingPermission?.id == "r1")
        // Un control_response cualquiera en el log NO cierra el permiso (podría escribirlo
        // una herramienta del propio agente): solo la marca de Argos.
        let answer = AgentProtocol.encodePermissionResponse(requestID: "r1", decision: .allow(updatedInput: .object([:])))
        AgentReducer.apply(try #require(AgentProtocol.decode(line: answer)), to: &state, echoesUserMessages: true)
        #expect(state.pendingPermission?.id == "r1")
        let marker = #"{"request_id":"r1","type":"argos_permission_answered"}"#
        AgentReducer.apply(try #require(AgentProtocol.decode(line: marker)), to: &state, echoesUserMessages: true)
        #expect(state.pendingPermission == nil)
    }

    @Test func losPromptsDeSubagentesYSinteticosNoSeHacenPasarPorElUsuario() throws {
        var state = AgentConversationState()
        let sub = #"{"type":"user","parent_tool_use_id":"toolu_1","message":{"content":"instrucciones al subagente"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"<system>…</system>"}}"#
        let top = #"{"type":"user","parent_tool_use_id":null,"message":{"content":"hola"}}"#
        for line in [sub, meta, top] {
            AgentReducer.apply(try #require(AgentProtocol.decode(line: line)), to: &state, echoesUserMessages: true)
        }
        #expect(state.items.map(\.kind) == [.userText("hola")])
    }

    @MainActor
    @Test func lanzarLocalizaClaudeYEjecutaElLanzador() async throws {
        let mock = MockSSHService()
        mock.agentScript = ["4242"]
        let session = try await PersistentAgentSession.launch(
            service: mock, workingDirectory: "/srv/app", title: "app", oauthToken: "tok-123"
        )
        #expect(PersistentAgentScript.isValidID(session.id))
        #expect(session.isAlive)
        let launch = try #require(mock.lastAgentCommand)
        #expect(launch.contains("mkfifo in"))
        #expect(launch.contains("--session-id \(session.id)"))
        #expect(!launch.contains("tok-123")) // el token nunca en la línea de comandos…
        #expect(mock.agentStdinLines.first == "tok-123") // …sino por stdin
    }

    @MainActor
    @Test func siOtroDispositivoLoEstaArrancandoAvisa() async {
        let mock = MockSSHService()
        mock.agentScript = ["ARGOS_AGENT_BUSY"]
        await #expect(throws: PersistentAgentError.busy) {
            _ = try await PersistentAgentSession.launch(service: mock, workingDirectory: "/", title: "x", oauthToken: nil)
        }
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
        #expect(mock.agentScripts[0].contains("exec 3<>"))
        #expect(session.state.status == .working)

        await session.send("   ")
        #expect(mock.agentScripts.count == 1) // vacío: no se envía

        let request = AgentPermissionRequest(id: "r9", toolName: "Bash", displayName: nil, input: .object([:]), toolUseID: nil)
        await session.respond(to: request, decision: .deny(message: "no"))
        #expect(mock.agentScripts[1].contains(PersistentAgentScript.answeredEventType) == false) // va en base64
        #expect(mock.agentScripts[1].contains(">> \"$HOME/.config/argos/agents/"))
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

@Suite("Avisos de agentes")
struct AgentAttentionTests {

    private let permiso = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"#
    private let respondido = #"{"type":"argos_permission_answered","request_id":"r1"}"#
    private let resultado = #"{"type":"result","subtype":"success","is_error":false,"result":"Listo: 3 tests verdes."}"#
    private let prompt = #"{"type":"user","message":{"content":"otra cosa"}}"#

    @Test func detectaPermisoPendienteYTerminado() {
        #expect(AgentAttention.evaluate(logTail: permiso) == .needsPermission(tool: "Bash"))
        #expect(AgentAttention.evaluate(logTail: [permiso, respondido].joined(separator: "\n")) == .none)
        #expect(AgentAttention.evaluate(logTail: [permiso, respondido, resultado].joined(separator: "\n"))
                == .finished(summary: "Listo: 3 tests verdes.", isError: false))
        // Tras un resultado, un prompt nuevo significa que vuelve a trabajar.
        #expect(AgentAttention.evaluate(logTail: [resultado, prompt].joined(separator: "\n")) == .none)
        // La primera línea cortada (trozo del final del log) se ignora.
        #expect(AgentAttention.evaluate(logTail: "a\":1}\n" + resultado) != .none)
    }

    @Test func soloAvisaDeLoNuevoYUnaVez() {
        let viejo = Date(timeIntervalSince1970: 1)
        let ahora = Date(timeIntervalSince1970: 1_000_000)
        func snap(_ bytes: Int, created: Date = viejo, tail: String) -> AgentLogSnapshot {
            AgentLogSnapshot(id: "6a55640d-ac70-41ab-8426-6eb72d4fb5eb", isAlive: true, logBytes: bytes,
                             title: "tienda", createdAt: created, tail: tail)
        }
        // Agente viejo nunca visto: solo referencia.
        var r = AgentAttentionPlanner.notices(snapshots: [snap(100, tail: resultado)], seenBytes: [:], now: ahora)
        #expect(r.notices.isEmpty)
        // Creció y terminó: aviso.
        r = AgentAttentionPlanner.notices(snapshots: [snap(200, tail: resultado)], seenBytes: r.seen, now: ahora)
        #expect(r.notices.first?.title == "tienda: Claude terminó")
        #expect(r.notices.first?.body == "Listo: 3 tests verdes.")
        // Sin cambios: no se repite.
        r = AgentAttentionPlanner.notices(snapshots: [snap(200, tail: resultado)], seenBytes: r.seen, now: ahora)
        #expect(r.notices.isEmpty)
        // Agente reciente nunca visto que pide permiso: aviso.
        let nuevo = AgentAttentionPlanner.notices(snapshots: [snap(50, created: ahora, tail: permiso)], seenBytes: [:], now: ahora)
        #expect(nuevo.notices.first?.title == "tienda: Claude espera tu permiso")
        // Los agentes que desaparecen se olvidan.
        #expect(AgentAttentionPlanner.notices(snapshots: [], seenBytes: r.seen, now: ahora).seen.isEmpty)
    }

    @Test func parseaLasInstantaneas() throws {
        let meta = try JSONEncoder.projects.encode(PersistentAgentMeta(workingDirectory: "/srv", title: "srv", createdAt: Date(timeIntervalSince1970: 5)))
        let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
        let output = "\(id)|1|42|\(meta.base64EncodedString())|\(Data(resultado.utf8).base64EncodedString())\nbasura|x"
        let snapshots = PersistentAgentScript.parseSnapshots(output)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].logBytes == 42 && snapshots[0].title == "srv" && snapshots[0].tail == resultado)
    }
}
