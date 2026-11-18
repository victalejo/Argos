//
//  IntegrationAgentHarness.swift
//  ArgosTests
//
//  Agentes persistentes de verdad (scripts de `PersistentAgentScript`/`PersistentAgentShell`)
//  con el `claude` SIMULADO que instala `sshd-test-start.sh` (`scripts/argos-fake-claude`).
//  El lanzamiento reproduce `PersistentAgentSession.start` con la ruta del simulado (nunca
//  se busca otro `claude`); enviar, engancharse, parar y reanudar usan el código real.
//

import Foundation
import Testing
@testable import Argos

/// Un agente lanzado en el servidor de pruebas.
struct LaunchedAgent: Sendable {
    let id: String
    let workingDirectory: String
    let meta: PersistentAgentMeta
    /// Marca para reconocer los hijos que lanza el simulado (`argos-fake-child-<token>`).
    let token: String

    var directory: String { PersistentAgentScript.directory(id) }
    var childPattern: String { "argos-fake-child-\(token)" }
}

/// Sin vigilante: las pruebas que lo quieren lo piden con plazos de segundos.
let noHibernation = PersistentAgentHibernation(idleSeconds: 0, checkSeconds: 1)

extension RemoteBox {

    /// `claude` simulado del HOME aislado.
    var fakeClaude: String { "\(home)/.local/bin/claude" }

    /// Lanza un agente nuevo con las variantes `modes` del simulado (ver su cabecera; el
    /// token se añade solo a `spawn-child` y `busy-child`).
    func launchAgent(
        modes: [String] = [],
        hibernation: PersistentAgentHibernation = noHibernation,
        title: String = "agente de prueba"
    ) async throws -> LaunchedAgent {
        let id = UUID().uuidString.lowercased()
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let workdir = "\(root)/agente-\(id.prefix(8))"
        let modeText = modes.map { $0.hasSuffix("-child") ? "\($0) \(token)" : $0 }.joined(separator: "\n")
        try await sh("mkdir -p \(q(workdir)) && printf '%s\\n' \(q(modeText)) > \(q(workdir + "/.argos-fake-mode"))")
        let meta = PersistentAgentMeta(
            workingDirectory: workdir, title: title, createdAt: Date(),
            permissionMode: ClaudeAgentCommand.PermissionMode.default.rawValue
        )
        try await start(id: id, meta: meta, resume: false, hibernation: hibernation)
        return LaunchedAgent(id: id, workingDirectory: workdir, meta: meta, token: token)
    }

    /// Lo mismo que `PersistentAgentSession.start`, con la ruta del simulado.
    func start(id: String, meta: PersistentAgentMeta, resume: Bool, hibernation: PersistentAgentHibernation) async throws {
        let invocation = ClaudeAgentCommand.persistent(
            claudePath: fakeClaude, sessionID: id, resume: resume, permissionMode: meta.resolvedPermissionMode
        )
        let command = try PersistentAgentScript.launch(id: id, meta: meta, claudeInvocation: invocation, hibernation: hibernation)
        let reply = try await AgentStdinExchange.firstLine(
            service: service, command: command, input: ClaudeAgentCommand.tokenLine(nil),
            timeout: .seconds(60), accept: PersistentAgentSession.isLaunchReply
        )
        try PersistentAgentSession.parseLaunchReply(reply)
    }

    /// Sesión cliente (la de la app) de un agente ya lanzado.
    @MainActor
    func session(for agent: LaunchedAgent, hibernation: PersistentAgentHibernation = noHibernation) async throws -> PersistentAgentSession {
        let listed = try await PersistentAgentSession.list(service: service)
        let info = listed.first { $0.id == agent.id }
            ?? PersistentAgentInfo(id: agent.id, isAlive: true, logBytes: 0, meta: agent.meta)
        return PersistentAgentSession(service: service, info: info, hibernation: { hibernation })
    }

    func isAlive(_ agent: LaunchedAgent) async throws -> Bool {
        try await sh("if \(PersistentAgentScript.aliveCheck(agent.id)); then echo vivo; fi").contains("vivo")
    }

    /// Procesos (línea de comandos) que contienen `pattern` (letras, cifras y guiones). El
    /// truco `[a]rgos…` evita contar el propio `sh -c` que ejecuta la búsqueda.
    func processes(matching pattern: String) async throws -> [String] {
        try await sh("ps -eo args= | grep -e \(q(Self.selfExcluding(pattern))); true")
            .split(separator: "\n").map(String.init)
    }

    static func selfExcluding(_ pattern: String) -> String {
        guard let first = pattern.first else { return pattern }
        return "[\(first)]\(pattern.dropFirst())"
    }

    /// Lo que el simulado anotó (argumentos de cada arranque y bytes de cada línea recibida).
    func fakeCalls(_ agent: LaunchedAgent) async throws -> [String] {
        try await read(agent.workingDirectory + "/.argos-fake-calls").split(separator: "\n").map(String.init)
    }

    func agentLog(_ agent: LaunchedAgent) async throws -> String {
        try await sh("cat \(agent.directory)/out.ndjson 2>/dev/null; true")
    }

    func agentMeta(_ agent: LaunchedAgent) async throws -> String {
        try await sh("cat \(agent.directory)/meta.json 2>/dev/null; true")
    }

    /// Para y borra los agentes y mata sus hijos (limpieza del test; nunca lanza).
    func removeAgents(_ agents: [LaunchedAgent]) async {
        for agent in agents {
            _ = try? await sh(PersistentAgentScript.stop(id: agent.id, delete: true, graceSeconds: 2))
            _ = try? await sh("pkill -KILL -f -- \(q(Self.selfExcluding(agent.childPattern))); true")
        }
    }
}

extension PersistentAgentSession {
    /// Textos del asistente que hay ahora en la conversación.
    var assistantTexts: [String] {
        state.items.compactMap { if case .assistantText(let text) = $0.kind { return text } else { return nil } }
    }

    var userTexts: [String] {
        state.items.compactMap { if case .userText(let text) = $0.kind { return text } else { return nil } }
    }
}
