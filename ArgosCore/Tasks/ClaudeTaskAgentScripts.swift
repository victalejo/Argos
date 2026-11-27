//
//  ClaudeTaskAgentScripts.swift
//  ArgosCore
//
//  Scripts de un encargo en agente persistente (lógica pura). La app los prepara al
//  encolar con las mismas piezas que el panel de agentes (`PersistentAgentScript`,
//  `ClaudeAgentCommand`, `GitWorktreeCommands`) y el despachador del servidor solo los
//  ejecuta cuando le toca, aunque la app esté cerrada:
//   - `launch.sh`: crea el worktree con su rama y arranca claude headless en él.
//   - `send.sh`: entrega el encargo por la FIFO del agente (en base64, sin shell).
//

import Foundation

enum ClaudeTaskAgentError: LocalizedError, Equatable {
    case promptTooLong

    var errorDescription: String? {
        switch self {
        case .promptTooLong:
            return String(localized: "El encargo es demasiado largo para un agente (más de 12 KB). Acórtalo o envíalo a la terminal.")
        }
    }
}

enum ClaudeTaskAgentScripts {

    struct Scripts: Equatable {
        let launch: String
        let send: String
    }

    /// Por debajo del tope de una línea en la FIFO, con margen para el JSON.
    static let maxPromptBytes = 12 * 1024

    static func make(
        request: ClaudeTaskRequest,
        agentID: String,
        worktree: String,
        branch: String,
        projectPath: String,
        claudePath: String,
        now: Date = Date()
    ) throws -> Scripts {
        guard request.prompt.utf8.count <= maxPromptBytes else { throw ClaudeTaskAgentError.promptTooLong }
        let worktreeCommand = GitWorktreeCommands.add(GitWorktreeRequest(
            repository: projectPath, branch: branch, createsBranch: true, base: "HEAD", path: worktree
        ))
        let meta = PersistentAgentMeta(
            workingDirectory: worktree, title: request.title, createdAt: now,
            permissionMode: request.permissionMode.rawValue
        )
        let invocation = ClaudeAgentCommand.persistent(
            claudePath: claudePath, sessionID: agentID, resume: false, permissionMode: request.permissionMode
        )
        // El worktree, sin tocar stdin: el lanzador lee de ahí la línea del token (vacía).
        let launch = "\(worktreeCommand) </dev/null >/dev/null 2>&1 || exit 1\n"
            + (try PersistentAgentScript.launch(id: agentID, meta: meta, claudeInvocation: invocation)) + "\n"
        let send = PersistentAgentScript.send(id: agentID, line: AgentProtocol.encodeUserMessage(text: request.prompt)) + "\n"
        return Scripts(launch: launch, send: send)
    }
}
