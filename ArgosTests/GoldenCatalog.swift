//
//  GoldenCatalog.swift
//  ArgosTests
//
//  Contenido de cada golden de paridad con Android, generado con el código Swift real y
//  con EXACTAMENTE las entradas que usan los tests de Kotlin (`SwiftParityGoldenTest`,
//  `PersistentAgentGoldenTest`, `GitTest`…). Cambiar una entrada aquí obliga a cambiarla
//  también allí.
//

import Foundation
@testable import Argos

enum GoldenCatalog {

    static let agentID = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    static let otherAgentID = "11111111-2222-3333-4444-555555555555"

    /// nombre del golden (sin `.txt`) → contenido.
    static func all() throws -> [String: String] {
        var result: [String: String] = [:]
        for part in [try agentProtocol(), try persistentAgent(), try agentHardening(), try commands(), try hooksAndStatus(), homeFiles(), androidClosing()] {
            result.merge(part) { _, _ in preconditionFailure("golden duplicado") }
        }
        return result
    }

    // MARK: - Protocolo stream-json y comandos de claude

    private static func agentProtocol() throws -> [String: String] {
        let rawInput = #"{"z":1,"a":1.50,"n":null,"b":true,"f":false,"arr":[1,2.0,"x/y",[],{}],"e":1e-7,"big":1e20,"#
            + #""neg":-0.5,"pi":3.14159,"third":0.3333333333333333,"obj":{"B":1,"a":2,"_":3,"a10":1,"a9":2,"Á":4}}"#
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(rawInput.utf8))
        return [
            "user-message": AgentProtocol.encodeUserMessage(text: "hola mundo"),
            "user-message-tricky": AgentProtocol.encodeUserMessage(
                text: "a/b \"q\" \\ \n\t\r\u{8}\u{C}\u{1}\u{1F}\u{7F}\u{2028} ñ 😀 </script>"
            ),
            "permission-allow": AgentProtocol.encodePermissionResponse(requestID: "req-9", decision: .allow(updatedInput: input)),
            "permission-allow-empty": AgentProtocol.encodePermissionResponse(requestID: "r1", decision: .allow(updatedInput: .object([:]))),
            "permission-deny": AgentProtocol.encodePermissionResponse(
                requestID: "req/9", decision: .deny(message: "El usuario denegó esta acción.")
            ),
            "build-bypass": ClaudeAgentCommand.build(
                claudePath: "/usr/bin/claude", workingDirectory: "~/mi proyecto", sessionID: "11111111-1111-1111-1111-111111111111"
            ),
            "build-accept": ClaudeAgentCommand.build(
                claudePath: "/opt/c laude", workingDirectory: "/tmp/a b; rm -rf ~", sessionID: "s", permissionMode: .acceptEdits
            ),
            "persistent-bypass": ClaudeAgentCommand.persistent(
                claudePath: "/usr/bin/claude", sessionID: agentID, resume: false, permissionMode: .bypassPermissions
            ),
            "token-line": String(decoding: ClaudeAgentCommand.tokenLine(" sk-ant\nPROMPT tok\t"), as: UTF8.self),
            "persistent-new": ClaudeAgentCommand.persistent(claudePath: "/usr/bin/claude", sessionID: agentID, resume: false),
            "persistent-resume": ClaudeAgentCommand.persistent(
                claudePath: "/usr/bin/claude", sessionID: agentID, resume: true, permissionMode: .plan
            ),
            "notification-body": AgentAttention.finished(summary: String(repeating: "👍🏽", count: 200), isError: false)
                .notification(agentTitle: "t")?.body ?? "",
        ]
    }

    // MARK: - Agente persistente (lanzar, enviar, enganche, parar, listar)

    static var meta: PersistentAgentMeta {
        PersistentAgentMeta(
            workingDirectory: "~/proyectos/tienda", title: "tienda \"ñ\" a/b",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.750)
        )
    }

    private static func persistentAgent() throws -> [String: String] {
        let id = agentID
        let invocation = ClaudeAgentCommand.persistent(claudePath: "/usr/bin/claude", sessionID: id, resume: false)
        var hibernated = meta
        hibernated.permissionMode = "plan"
        hibernated.hibernatedAt = Date(timeIntervalSince1970: 1_800_003_600)
        return [
            "meta-json": String(decoding: try JSONEncoder.projects.encode(meta), as: UTF8.self),
            "meta-json-hibernated": String(decoding: try JSONEncoder.projects.encode(hibernated), as: UTF8.self),
            "launch": try PersistentAgentScript.launch(id: id, meta: meta, claudeInvocation: invocation),
            "launch-no-hibernation": try PersistentAgentScript.launch(
                id: id, meta: meta, claudeInvocation: invocation, hibernation: PersistentAgentHibernation(idleHours: 0)
            ),
            "launch-hibernation-1h": try PersistentAgentScript.launch(
                id: id, meta: meta, claudeInvocation: invocation, hibernation: PersistentAgentHibernation(idleHours: 1)
            ),
            "send": PersistentAgentScript.send(id: id, line: #"{"type":"user","message":{"content":"$(rm -rf ~) `id` 'hola'"}}"#),
            "send-answered": PersistentAgentScript.send(id: id, line: "{}", answeredRequestID: "r\"1/x"),
            "send-stdin": PersistentAgentScript.sendViaStdin(id: id, byteCount: 70_001),
            "send-stdin-answered": PersistentAgentScript.sendViaStdin(
                id: id, byteCount: 20_000, answeredRequestID: "r\"1/x", timeoutSeconds: 2
            ),
            "attach": PersistentAgentScript.attach(id: id),
            "attach-from": PersistentAgentScript.attach(id: id, fromByte: 2048),
            "stop": PersistentAgentScript.stop(id: id, delete: false),
            "stop-delete": PersistentAgentScript.stop(id: id, delete: true),
            "stop-grace": PersistentAgentScript.stop(id: id, delete: false, graceSeconds: 1),
            "hibernate": PersistentAgentScript.hibernate(id: id, minIdleSeconds: 3600),
            "error-tail": PersistentAgentScript.errorTail(id: id),
            "list": PersistentAgentScript.list(),
            "snapshots": PersistentAgentScript.snapshots(),
        ]
    }

    // MARK: - Trozos de shell, inventario, guardia y topes

    private static func agentHardening() throws -> [String: String] {
        let id = agentID
        let dir = PersistentAgentScript.directory(id)
        let longText = String(repeating: "é👍🏽a", count: 6_000)
        return [
            "watchdog": PersistentAgentShell.watchdog(id: id, idleSeconds: 14_400, checkSeconds: 300),
            "rotate-log": PersistentAgentShell.rotateOutputLog(dir),
            "rotate-log-small": PersistentAgentShell.rotateOutputLog(dir, maxBytes: 200_000, keepBytes: 100_000),
            "trim-err-log": PersistentAgentShell.trimErrorLog(dir),
            "mark-hibernated": PersistentAgentShell.markHibernated(dir),
            "terminate-process": PersistentAgentShell.terminateProcess(id: id, graceSeconds: 3),
            "inventory": ServerAgentInventory.script(),
            "inventory-stop": ServerAgentInventory.stopPersistent(ids: [id, "no-es-un-uuid", otherAgentID]),
            "inventory-hibernate": ServerAgentInventory.hibernate(ids: [id, otherAgentID], minIdleSeconds: 7200),
            "inventory-stop-panel": ServerAgentInventory.stopPanel([(pid: 4242, sessionID: otherAgentID.uppercased()), (pid: 1, sessionID: id)]),
            "inventory-stop-panel-sessions": ServerAgentInventory.stopPanelSessions([otherAgentID, "x"]),
            "hibernation-warning": PersistentAgentHibernation.backgroundWorkWarning,
            "launch-guard": [
                AgentLaunchGuard.assess(freeMemoryKB: 512_000, liveAgents: 0),
                AgentLaunchGuard.assess(freeMemoryKB: 850, liveAgents: 0),
                AgentLaunchGuard.assess(freeMemoryKB: 2_000_000, liveAgents: 7),
                AgentLaunchGuard.assess(freeMemoryKB: nil, liveAgents: 6),
            ].map(describe).joined(separator: "\n"),
            "tool-result-clip": AgentTranscriptLimits.clip(longText),
            "remote-timeout": RemoteTimeout.wrap("tmux list-sessions -F '#{session_name}' | grep \"$x\""),
            "remote-timeout-short": RemoteTimeout.wrap("true", seconds: 0),
        ]
    }

    private static func describe(_ assessment: AgentLaunchGuard.Assessment) -> String {
        switch assessment {
        case .ok: return "ok"
        case .warning(let title, let message): return "\(title)|\(message)"
        }
    }
}
