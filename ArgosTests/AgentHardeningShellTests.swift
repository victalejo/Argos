//
//  AgentHardeningShellTests.swift
//  ArgosTests
//
//  Ejecuta DE VERDAD los scripts remotos del agente persistente con un «claude»
//  simulado, en bash (`/bin/sh` de macOS) y en DASH (el `sh` de Debian/Ubuntu: también
//  los `sh -c` internos, con un `sh` de dash al principio del PATH). Cubre hibernación,
//  parada con escalado a KILL y al GRUPO (con un `setsid` simulado), PID reutilizado,
//  envío por stdin de líneas enormes con el agente muerto o sin leer, rotación con un
//  `tail -F` enganchado, fallo al arrancar y avisos con líneas recortadas.
//

import Foundation
import Testing
@testable import Argos

@Suite("Agente persistente: scripts ejecutados con sh y dash", .serialized)
struct AgentHardeningShellTests {

    static let shells = ["/bin/sh", "/bin/dash"]
    private let id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"

    // MARK: - Utilidades

    struct Run {
        let status: Int32
        let output: String
    }

    /// Carpeta de pruebas con `bin/` delante del PATH: `sh` es el shell probado (para los
    /// `sh -c` internos) y, con `setsid`, un `setsid` simulado con perl.
    private func makeHome(shell: String, setsid: Bool = false) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("argos-hard-\(UUID())")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if Self.traceShell {
            // Diagnóstico: cada `sh -c` interno (lanzador, vigilante) deja su traza.
            let wrapper = bin.appendingPathComponent("sh")
            try "#!\(shell)\nexec \(shell) -x \"$@\" 2>>\"$HOME/sh-trace.log\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        } else {
            try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("sh").path, withDestinationPath: shell)
        }
        if setsid {
            let fake = bin.appendingPathComponent("setsid")
            try "#!/bin/sh\nexec /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV or die' \"$@\"\n"
                .write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        }
        return home
    }

    /// Diagnóstico (variables de entorno del proceso de tests): conservar las carpetas de
    /// prueba y trazar los `sh -c` internos.
    static let keepHomes = ProcessInfo.processInfo.environment["ARGOS_KEEP_TEST_HOMES"] != nil
    static let traceShell = ProcessInfo.processInfo.environment["ARGOS_TRACE_SHELL"] != nil

    private func cleanUp(_ home: URL) {
        if Self.keepHomes {
            print("Carpeta de prueba conservada: \(home.path)")
        } else {
            try? FileManager.default.removeItem(at: home)
        }
    }

    @discardableResult
    private func sh(_ command: String, home: URL, shell: String, stdin: Data? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "\(home.path)/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
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

    /// «claude» falso: por cada línea de la FIFO responde (con `permiso`, pide un permiso;
    /// si no, cierra el turno con un `result`). `ignoreTerm`: no muere con TERM. `child`:
    /// deja un hijo `sleep` (como un comando de Bash del agente) cuyo PID anota.
    /// `deaf`: nunca lee la FIFO. `failing`: muere al arrancar.
    private func fakeClaude(
        home: URL, ignoreTerm: Bool = false, child: Bool = false, deaf: Bool = false, failing: Bool = false
    ) throws -> String {
        let fake = home.appendingPathComponent("claude-falso.sh")
        var lines = ["#!/bin/sh"]
        if failing {
            lines += ["echo 'error: unknown option --foo' >&2", "exit 1"]
        } else {
            if ignoreTerm { lines.append("trap '' TERM") }
            if child { lines.append("sleep 300 & echo $! > \"$HOME/child.pid\"") }
            if deaf {
                lines.append("while true; do sleep 1; done")
            } else {
                lines += [
                    "while IFS= read -r line; do",
                    "  case \"$line\" in",
                    "    *permiso*) printf '%s\\n' '{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{}}}' ;;",
                    "    *) printf '{\"type\":\"echo\",\"bytes\":%s}\\n' \"${#line}\"; printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\"}' ;;",
                    "  esac",
                    "done",
                ]
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return "\(ShellQuoting.singleQuoted(fake.path)) --session-id \(id)"
    }

    private func meta(_ home: URL) -> PersistentAgentMeta {
        PersistentAgentMeta(workingDirectory: home.path, title: "t", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func agentDir(_ home: URL) -> URL {
        home.appendingPathComponent(".config/argos/agents/\(id)")
    }

    private func listed(_ home: URL, shell: String) throws -> PersistentAgentInfo? {
        PersistentAgentScript.parseList(try sh(PersistentAgentScript.list(), home: home, shell: shell).output).first
    }

    private func waitUntil(seconds: Double, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try condition()
    }

    private func launch(_ home: URL, shell: String, invocation: String, hibernation: PersistentAgentHibernation = .init(idleHours: 0)) throws -> Run {
        let command = try PersistentAgentScript.launch(id: id, meta: meta(home), claudeInvocation: invocation, hibernation: hibernation)
        return try sh(command, home: home, shell: shell, stdin: Data("\n".utf8))
    }

    private func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Plazo generoso para esperar CONDICIONES (nunca tiempos fijos): con la máquina
    /// cargada todo tarda más, pero la condición acaba cumpliéndose.
    static let patience: Double = 60

    private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#
    private let permissionLine = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"#

    private func log(_ home: URL) -> String {
        (try? String(contentsOf: agentDir(home).appendingPathComponent("out.ndjson"), encoding: .utf8)) ?? ""
    }

    /// Prepara la carpeta del agente con un log ya escrito (lo que dejó una conversación
    /// anterior), ANTES de lanzar: el vigilante ve ese estado desde su primera vuelta.
    private func seedLog(_ home: URL, lines: [String]) throws {
        try FileManager.default.createDirectory(at: agentDir(home), withIntermediateDirectories: true)
        try (lines.map { $0 + "\n" }.joined()).write(to: agentDir(home).appendingPathComponent("out.ndjson"), atomically: true, encoding: .utf8)
    }

    /// Prueba de vida del vigilante: cada vuelta recorta `err.log` si pasa de 256 KiB. Se
    /// infla y se espera a verlo recortado DOS veces: la vuelta del primer recorte puede
    /// estar a medias, la del segundo empezó después y completó entera su evaluación.
    private func waitForTwoWatchdogRounds(_ home: URL) async throws -> Bool {
        let errLog = agentDir(home).appendingPathComponent("err.log")
        let filler = Data(repeating: UInt8(ascii: "e"), count: PersistentAgentShell.errLogMaxBytes + 1_024)
        for _ in 0..<2 {
            try filler.write(to: errLog)
            let trimmed = try await waitUntil(seconds: Self.patience) {
                ((try? FileManager.default.attributesOfItem(atPath: errLog.path)[.size] as? Int) ?? Int.max)
                    <= PersistentAgentShell.errLogKeepBytes
            }
            guard trimmed else { return false }
        }
        return true
    }

    // MARK: - Arranque

    /// El lanzador solo espera 1 s: si claude muere antes, lo dice (`ARGOS_AGENT_FAILED`
    /// con su error); si tarda más (máquina cargada), responde su PID y es el cliente quien
    /// lo detecta después (`PersistentAgentSession.watchStartup`). El test comprueba ese
    /// contrato en los dos caminos, sin depender de cuál toque.
    @Test(arguments: shells) func siClaudeMuereAlArrancarSeDiceElPorque(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let run = try launch(home, shell: shell, invocation: try fakeClaude(home: home, failing: true))
        let line = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix(PersistentAgentScript.failedReply) {
            #expect(run.status == 6)
            #expect(throws: PersistentAgentError.launchFailed("error: unknown option --foo\n")) {
                try PersistentAgentSession.parseLaunchReply(line)
            }
        } else {
            #expect(run.status == 0 && Int32(line) != nil, "salida: \(run.output)")
            #expect(try await waitUntil(seconds: Self.patience) { try listed(home, shell: shell)?.isAlive == false })
        }
        // En los dos caminos el motivo queda donde el cliente lo lee.
        let tail = try sh(PersistentAgentScript.errorTail(id: id), home: home, shell: shell).output
        #expect(tail.contains("error: unknown option --foo"))
    }

    // MARK: - Hibernación

    @Test(arguments: shells) func elVigilanteHibernaUnAgenteQuietoYSeReanuda(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let invocation = try fakeClaude(home: home)
        // Una conversación ya terminada (último evento: `result`): quieta desde el principio.
        try seedLog(home, lines: [resultLine])
        let run = try launch(home, shell: shell, invocation: invocation, hibernation: .init(idleSeconds: 1, checkSeconds: 1))
        #expect(Int(run.output.trimmingCharacters(in: .whitespacesAndNewlines)) != nil, "salida: \(run.output)")

        let hibernated = try await waitUntil(seconds: Self.patience) {
            try listed(home, shell: shell).map { !$0.isAlive && $0.meta.isHibernated } ?? false
        }
        #expect(hibernated)
        // Con la marca puesta, un envío ya no se da por entregado.
        #expect(throws: (any Error).self) {
            let result = try sh(PersistentAgentScript.send(id: id, line: "{}"), home: home, shell: shell)
            if result.status != 0 { throw NSError(domain: "sh", code: Int(result.status)) }
        }
        let raw = try Data(contentsOf: agentDir(home).appendingPathComponent("meta.json"))
        let decoded = try JSONDecoder.projects.decode(PersistentAgentMeta.self, from: raw)
        #expect(decoded.title == "t" && decoded.hibernatedAt != nil)

        // Reanudar (el cliente quita la marca) lo vuelve a poner en marcha.
        _ = try launch(home, shell: shell, invocation: invocation)
        let info = try #require(try listed(home, shell: shell))
        #expect(info.isAlive && !info.meta.isHibernated)
        _ = try sh(PersistentAgentScript.stop(id: id, delete: true), home: home, shell: shell)
    }

    @Test(arguments: shells) func noHibernaSiEsperaUnPermiso(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        // El permiso ya está pendiente ANTES de lanzar: no hay carrera con el envío (antes
        // el vigilante podía ver el log vacío, que sí es «quieto», si el envío se retrasaba).
        try seedLog(home, lines: [resultLine, #"{"type":"user","message":{"content":"haz algo"}}"#, permissionLine])
        _ = try launch(home, shell: shell, invocation: try fakeClaude(home: home), hibernation: .init(idleSeconds: 1, checkSeconds: 1))
        // Dos vueltas completas del vigilante con el log inactivo y el permiso pendiente.
        #expect(try await waitForTwoWatchdogRounds(home))
        #expect(try listed(home, shell: shell)?.isAlive == true)
        // A demanda tampoco: el servidor vuelve a comprobar la quietud.
        let output = try sh(PersistentAgentScript.hibernate(id: id, minIdleSeconds: 0), home: home, shell: shell).output
        #expect(!output.contains(PersistentAgentScript.hibernatedReply))
        #expect(try listed(home, shell: shell)?.isAlive == true)
        // Control positivo: respondido y terminado el turno, el MISMO vigilante lo hiberna.
        let done = #"{"request_id":"r1","type":"argos_permission_answered"}"# + "\n" + resultLine + "\n"
        let handle = try FileHandle(forWritingTo: agentDir(home).appendingPathComponent("out.ndjson"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(done.utf8))
        try handle.close()
        #expect(try await waitUntil(seconds: Self.patience) {
            try listed(home, shell: shell).map { !$0.isAlive && $0.meta.isHibernated } ?? false
        })
        _ = try sh(PersistentAgentScript.stop(id: id, delete: true), home: home, shell: shell)
        #expect(!FileManager.default.fileExists(atPath: agentDir(home).path))
    }

    @Test(arguments: shells) func hibernarADemandaRespetaLaInactividadMinima(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        _ = try launch(home, shell: shell, invocation: try fakeClaude(home: home))
        _ = try sh(PersistentAgentScript.send(id: id, line: #"{"n":1}"#), home: home, shell: shell)
        // El simulado señala que terminó el turno escribiendo su `result`.
        #expect(try await waitUntil(seconds: Self.patience) { log(home).contains(#""type":"result""#) })
        // Recién activo: con 1 h de inactividad mínima, no se toca.
        let early = try sh(PersistentAgentScript.hibernate(id: id, minIdleSeconds: 3600), home: home, shell: shell).output
        #expect(!early.contains(PersistentAgentScript.hibernatedReply))
        #expect(try listed(home, shell: shell)?.isAlive == true)
        // Con 1 s de inactividad exigida acaba hibernándolo (se reintenta hasta que el log
        // lleva ese tiempo quieto, tarde lo que tarde la máquina).
        var late = ""
        #expect(try await waitUntil(seconds: Self.patience) {
            late = try sh(PersistentAgentScript.hibernate(id: id, minIdleSeconds: 1), home: home, shell: shell).output
            return late.contains(PersistentAgentScript.hibernatedReply)
        })
        #expect(late.contains("\(PersistentAgentScript.hibernatedReply) \(id)"))
        let info = try #require(try listed(home, shell: shell))
        #expect(!info.isAlive && info.meta.isHibernated)
    }

    @Test(arguments: shells) func elVigilanteNoTocaUnPIDReutilizado(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.projects.encode(meta(home)).write(to: dir.appendingPathComponent("meta.json"))
        try #"{"type":"result","subtype":"success","is_error":false,"result":"a"}"#.appending("\n")
            .write(to: dir.appendingPathComponent("out.ndjson"), atomically: true, encoding: .utf8)
        // Un proceso cualquiera (sin el id en su línea de comandos) con el PID guardado.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        try "\(other.processIdentifier)\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        // El log ya cuenta como inactivo: modificado hace una hora.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: dir.appendingPathComponent("out.ndjson").path)

        let watch = PersistentAgentShell.watchdog(id: id, idleSeconds: 1, checkSeconds: 1)
        let run = try sh("sh -c \(ShellQuoting.singleQuoted(watch)) argos-watch \(other.processIdentifier)", home: home, shell: shell)
        #expect(run.status == 0) // sale en cuanto ve que no es el agente
        _ = try sh(PersistentAgentScript.hibernate(id: id, minIdleSeconds: 0), home: home, shell: shell)
        _ = try sh(PersistentAgentScript.stop(id: id, delete: false, graceSeconds: 1), home: home, shell: shell)
        #expect(other.isRunning)
        #expect(!(try String(contentsOf: dir.appendingPathComponent("meta.json"), encoding: .utf8)).contains("hibernatedAt"))
    }

    @Test(arguments: shells) func marcarHibernadoEsIdempotenteYConservaElJSON(shell: String) throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        try FileManager.default.createDirectory(at: agentDir(home), withIntermediateDirectories: true)
        var original = meta(home)
        original.permissionMode = "plan"
        try JSONEncoder.projects.encode(original).write(to: agentDir(home).appendingPathComponent("meta.json"))
        let dir = PersistentAgentScript.directory(id)
        _ = try sh(PersistentAgentShell.markHibernated(dir), home: home, shell: shell)
        _ = try sh(PersistentAgentShell.markHibernated(dir), home: home, shell: shell)
        let text = try String(contentsOf: agentDir(home).appendingPathComponent("meta.json"), encoding: .utf8)
        #expect(text.components(separatedBy: "hibernatedAt").count == 2) // una sola vez
        let decoded = try JSONDecoder.projects.decode(PersistentAgentMeta.self, from: Data(text.utf8))
        #expect(decoded.permissionMode == "plan" && decoded.isHibernated)
    }

    // MARK: - Parar

    @Test(arguments: shells) func pararEscalaAKillYSoloBorraConElProcesoMuerto(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let run = try launch(home, shell: shell, invocation: try fakeClaude(home: home, ignoreTerm: true))
        let pid = try #require(Int32(run.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(isRunning(pid))
        let stop = try sh(PersistentAgentScript.stop(id: id, delete: true, graceSeconds: 1), home: home, shell: shell)
        #expect(stop.status == 0)
        // Ni con TERM ignorado sobrevive (se espera a que el sistema lo recoja: un zombi
        // aún responde a `kill(pid, 0)`).
        #expect(try await waitUntil(seconds: Self.patience) { !isRunning(pid) })
        #expect(!FileManager.default.fileExists(atPath: agentDir(home).path))
    }

    /// Con `setsid` claude es líder de su grupo: parar mata también a sus hijos. Prueba
    /// la forma `kill -s TERM -- -PGID`, que dash sí acepta.
    @Test(arguments: shells) func pararMataAlGrupoDelAgente(shell: String) async throws {
        let home = try makeHome(shell: shell, setsid: true)
        defer { cleanUp(home) }
        let run = try launch(home, shell: shell, invocation: try fakeClaude(home: home, child: true))
        let pid = try #require(Int32(run.output.trimmingCharacters(in: .whitespacesAndNewlines)), "salida: \(run.output)")
        let childFile = home.appendingPathComponent("child.pid")
        #expect(try await waitUntil(seconds: Self.patience) { FileManager.default.fileExists(atPath: childFile.path) })
        let child = try #require(Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(getpgid(pid) == pid) // líder de su propio grupo
        #expect(isRunning(child))
        _ = try sh(PersistentAgentScript.stop(id: id, delete: false, graceSeconds: 2), home: home, shell: shell)
        #expect(try await waitUntil(seconds: Self.patience) { !isRunning(pid) })
        #expect(try await waitUntil(seconds: Self.patience) { !isRunning(child) }) // el hijo cae con el grupo
    }

    // MARK: - Envío grande por stdin

    @Test(arguments: shells) func unaLineaEnormeLlegaPorStdinYSeCompruebaSuLongitud(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        _ = try launch(home, shell: shell, invocation: try fakeClaude(home: home))
        let line = #"{"type":"control_response","response":{"x":""# + String(repeating: "é", count: 90_000) + #""}}"#
        #expect(PersistentAgentScript.needsStdin(line: line))
        #expect(!PersistentAgentScript.needsStdin(line: "{}"))
        let payload = Data((line + "\n").utf8)

        let short = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: payload.count + 1), home: home, shell: shell, stdin: payload)
        #expect(short.output.contains(PersistentAgentScript.shortReply))

        let sent = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: payload.count, answeredRequestID: "r9"),
                          home: home, shell: shell, stdin: payload)
        #expect(sent.status == 0 && sent.output.contains(PersistentAgentScript.sentReply), "salida: \(sent.output)")
        let logURL = agentDir(home).appendingPathComponent("out.ndjson")
        #expect(try await waitUntil(seconds: Self.patience) {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").contains(#""bytes":"#)
        })
        #expect(try String(contentsOf: logURL, encoding: .utf8).contains(#""request_id":"r9""#))
        _ = try sh(PersistentAgentScript.stop(id: id, delete: true), home: home, shell: shell)
        let dead = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: 3), home: home, shell: shell, stdin: Data("{}\n".utf8))
        #expect(dead.output.contains(PersistentAgentScript.deadReply))
    }

    /// Más de 64 KB a un agente que no lee: el escritor se bloquearía para siempre. El
    /// script termina al morir el agente (o al vencer el plazo) y no deja nada colgado.
    @Test(arguments: shells) func unaLineaEnormeAUnAgenteQueNoLeeNoSeQuedaColgada(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let run = try launch(home, shell: shell, invocation: try fakeClaude(home: home, deaf: true))
        let pid = try #require(Int32(run.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let payload = Data((String(repeating: "z", count: 200_000) + "\n").utf8)

        // Vivo pero sin leer: vence el plazo.
        let started = Date()
        let timedOut = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: payload.count, timeoutSeconds: 2),
                              home: home, shell: shell, stdin: payload)
        #expect(timedOut.output.contains(PersistentAgentScript.timeoutReply))
        #expect(Date().timeIntervalSince(started) < Self.patience) // terminó: no se colgó

        // Muere a mitad de la escritura: se detecta enseguida.
        let killer = Task.detached {
            try? await Task.sleep(for: .seconds(1))
            kill(pid, SIGKILL)
        }
        let dead = try sh(PersistentAgentScript.sendViaStdin(id: id, byteCount: payload.count, timeoutSeconds: 20),
                          home: home, shell: shell, stdin: payload)
        await killer.value
        #expect(dead.output.contains(PersistentAgentScript.deadReply))
        // Ningún escritor `cat` se queda vivo con la línea vieja.
        // Ningún escritor `cat` de ESTA prueba se queda vivo (el que se mató puede tardar un
        // instante en desaparecer).
        let pattern = "[.]send[.]"
        #expect(try await waitUntil(seconds: Self.patience) {
            let leftover = try sh("ps -eo args= | grep -F -- \(ShellQuoting.singleQuoted(home.path)) | grep -c '\(pattern)' || true",
                                  home: home, shell: shell).output
            return leftover.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
        })
    }

    // MARK: - Rotación

    @Test(arguments: shells) func laRotacionConservaLosDesplazamientosAbsolutos(shell: String) throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.projects.encode(meta(home)).write(to: dir.appendingPathComponent("meta.json"))
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":""# + String(repeating: "z", count: 1_000) + "\"}]}}\n"
        let original = Data(String(repeating: line, count: 300).utf8)
        try original.write(to: dir.appendingPathComponent("out.ndjson"))
        try "150\n".write(to: dir.appendingPathComponent("log.base"), atomically: true, encoding: .utf8)

        let quoted = PersistentAgentScript.directory(id)
        _ = try sh(PersistentAgentShell.rotateOutputLog(quoted, maxBytes: 200_000, keepBytes: 100_000), home: home, shell: shell)

        let rotated = try Data(contentsOf: dir.appendingPathComponent("out.ndjson"))
        let base = try #require(Int(try String(contentsOf: dir.appendingPathComponent("log.base"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(rotated.count <= 100_000)
        #expect(rotated.first == UInt8(ascii: "{")) // empieza en una línea completa
        #expect(base + rotated.count == 150 + original.count) // la marca no cuenta
        // El log nuevo EMPIEZA por la marca (un `tail -F` que lo reabre la lee primero).
        #expect(String(decoding: rotated, as: UTF8.self).hasPrefix(PersistentAgentShell.rotatedLine + "\n"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".rotating").path))
        #expect(try listed(home, shell: shell)?.logBytes == 150 + original.count)

        // El enganche traduce el byte absoluto pedido al local y lo anuncia.
        // (Tras la marca inicial: sus bytes locales nunca se entregan.)
        let mark = PersistentAgentShell.rotatedLineBytes
        let header = try sh(PersistentAgentScript.attach(id: id, fromByte: base + mark + 11), home: home, shell: shell).output
            .split(separator: "\n").first.map(String.init) ?? ""
        let parsed = try #require(PersistentAgentScript.parseLogBase(header))
        #expect(parsed.base == base && parsed.from == mark + 11)
        // Lo pedido ya se rotó: desde el principio de lo conservado (tras la marca).
        let old = try sh(PersistentAgentScript.attach(id: id, fromByte: 5), home: home, shell: shell).output
            .split(separator: "\n").first.map(String.init) ?? ""
        #expect(PersistentAgentScript.parseLogBase(old)?.from == PersistentAgentShell.rotatedLineBytes + 1)
        // Más allá del final (desplazamientos que no cuadran): también reconstruye.
        let beyond = try sh(PersistentAgentScript.attach(id: id, fromByte: base + rotated.count + 5_000), home: home, shell: shell)
            .output.split(separator: "\n").first.map(String.init) ?? ""
        #expect(PersistentAgentScript.parseLogBase(beyond)?.from == PersistentAgentShell.rotatedLineBytes + 1)
    }

    /// Un `tail -F` enganchado durante la rotación ve la marca ANTES de la copia
    /// conservada (al final del viejo o al principio del nuevo); el cliente deja de contar
    /// ahí y sus desplazamientos no se inflan. El caso de no ver la del viejo, sin depender
    /// de la carga: `AgentHardeningRound3Tests`.
    @Test(arguments: shells) func rotarConUnTailEnganchadoNoInflaLosDesplazamientos(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":""# + String(repeating: "q", count: 1_000) + "\"}]}}\n"
        let original = Data(String(repeating: line, count: 300).utf8)
        try original.write(to: dir.appendingPathComponent("out.ndjson"))

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: shell)
        attach.arguments = ["-c", PersistentAgentScript.attach(id: id)]
        attach.environment = ["HOME": home.path, "PATH": "\(home.path)/bin:/usr/bin:/bin"]
        // A un archivo (no a una tubería): 400 KB llenarían el búfer y el tail se pararía.
        let outURL = home.appendingPathComponent("attach.out")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let input = Pipe()
        attach.standardOutput = out
        attach.standardInput = input
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        func receivedCount() -> Int { (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0 }
        // Que el tail haya entregado todo el log antes de rotar (cabecera + datos).
        #expect(try await waitUntil(seconds: Self.patience) { receivedCount() >= original.count + 40 })
        _ = try sh(PersistentAgentShell.rotateOutputLog(PersistentAgentScript.directory(id), maxBytes: 200_000, keepBytes: 100_000),
                   home: home, shell: shell)
        // tail -F entrega la marca y, al ver el archivo sustituido, reenvía la copia conservada.
        #expect(try await waitUntil(seconds: Self.patience) { receivedCount() >= original.count + 50_000 })
        try input.fileHandleForWriting.close()
        _ = try await waitUntil(seconds: Self.patience) { !attach.isRunning }
        if attach.isRunning { attach.terminate() }
        try out.close()
        let received = try Data(contentsOf: outURL)

        var buffer = NDJSONLineBuffer()
        var parser = AgentAttachStreamParser()
        var counted = 0
        var sawRotation = false
        for entry in buffer.appendCountingBytes(Array(received)) {
            switch parser.classify(text: entry.text) {
            case .data: counted += entry.byteCount
            case .rotated: sawRotation = true
            case .noise, .header: break
            }
        }
        #expect(sawRotation)
        #expect(received.count > original.count + 50_000) // el tail SÍ reenvió la copia…
        #expect(counted == original.count) // …pero el cliente no la cuenta
    }

    // MARK: - Avisos e inventario

    @Test(arguments: shells) func unPermisoEnormeSeAvisaAunqueToolNameVengaTarde(shell: String) throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.projects.encode(meta(home)).write(to: dir.appendingPathComponent("meta.json"))
        let big = String(repeating: "x", count: 100_000)
        let late = #"{"type":"control_request","request_id":"r5","request":{"subtype":"can_use_tool","input":{"content":""# + big + #""},"tool_name":"Write"}}"#
        try ("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"a\"}\n" + late + "\n")
            .write(to: dir.appendingPathComponent("out.ndjson"), atomically: true, encoding: .utf8)

        let snapshots = PersistentAgentScript.parseSnapshots(try sh(PersistentAgentScript.snapshots(), home: home, shell: shell).output)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.tail.utf8.count < 2_000)
        #expect(AgentAttention.evaluate(logTail: snapshot.tail) == .needsPermission(tool: "Write"))
    }

    @Test(arguments: shells) func elInventarioSeEjecutaYSeEntiende(shell: String) throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let dir = agentDir(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.projects.encode(meta(home)).write(to: dir.appendingPathComponent("meta.json"))
        try #"{"type":"result","subtype":"success","is_error":false,"result":"a"}"#.appending("\n")
            .write(to: dir.appendingPathComponent("out.ndjson"), atomically: true, encoding: .utf8)
        let run = try sh(ServerAgentInventory.script(), home: home, shell: shell)
        #expect(run.status == 0)
        let inventory = ServerAgentInventory.parse(run.output)
        let agent = try #require(inventory.agents.first { $0.sessionID == id })
        #expect(!agent.isAlive && !agent.hasPendingPermission)
        #expect((agent.idleSeconds ?? -1) >= 0)
    }

    /// Parar conversaciones del panel por id: mata la suya (aunque el PID se desconozca)
    /// y deja en paz un proceso con otro id y un shell que lleve el texto.
    @Test(arguments: shells) func pararConversacionesDelPanelPorID(shell: String) async throws {
        let home = try makeHome(shell: shell)
        defer { cleanUp(home) }
        let mine = "11111111-2222-3333-4444-555555555555"
        let other = "99999999-2222-3333-4444-555555555555"
        let fake = home.appendingPathComponent("claude")
        try "#!/usr/bin/perl\nsleep 60;\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        func spawn(_ session: String) throws -> Process {
            let process = Process()
            process.executableURL = fake
            process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                 "--permission-prompt-tool", "stdio", "--session-id", session]
            try process.run()
            return process
        }
        let target = try spawn(mine)
        let bystander = try spawn(other)
        defer { bystander.terminate(); target.terminate() }
        // Que los dos ya se vean en `ps` con su línea de comandos.
        #expect(try await waitUntil(seconds: Self.patience) {
            let listed = try sh("ps -eo args=", home: home, shell: shell).output
            return listed.contains(mine) && listed.contains(other)
        })
        _ = try sh(ServerAgentInventory.stopPanelSessions([mine]), home: home, shell: shell)
        #expect(try await waitUntil(seconds: Self.patience) { !target.isRunning })
        #expect(bystander.isRunning)
    }
}
