//
//  AgentSessionStore.swift
//  Argos
//
//  Pool de sesiones de agente (`ClaudeAgentSession`) indexado por `SessionHandle`.
//  Mantiene cada agente VIVO aunque cambies de sesión o de modo (Terminal/Agente):
//  volver al panel de un agente ya iniciado conserva su conversación.
//

import Observation

@MainActor
@Observable
final class AgentSessionStore {

    private var sessions: [SessionHandle: ClaudeAgentSession] = [:]

    /// Tope de agentes vivos a la vez (cada uno mantiene un proceso `claude` remoto).
    static let maxLiveSessions = 6

    /// Devuelve el agente ya iniciado para `handle`, si existe.
    func existing(for handle: SessionHandle) -> ClaudeAgentSession? {
        sessions[handle]
    }

    /// Inicia (o reutiliza) el agente de `handle` con el comando ya construido.
    @discardableResult
    func start(
        for handle: SessionHandle,
        service: any SSHServicing,
        command: String,
        workingDirectory: String
    ) -> ClaudeAgentSession {
        if let existing = sessions[handle] { return existing }
        let session = ClaudeAgentSession(
            service: service,
            command: command,
            workingDirectory: workingDirectory
        )
        sessions[handle] = session
        evictIfNeeded(keeping: handle)
        return session
    }

    /// Detiene y olvida el agente de `handle`.
    func close(_ handle: SessionHandle) {
        sessions[handle]?.stop()
        sessions.removeValue(forKey: handle)
    }

    /// Cierra todos los agentes de un servidor (al eliminarlo/editarlo).
    func closeAll(forServer serverID: Server.ID) {
        for handle in sessions.keys where handle.serverID == serverID {
            close(handle)
        }
    }

    /// Si se supera el tope, cierra los agentes más antiguos (excepto el recién creado).
    private func evictIfNeeded(keeping keep: SessionHandle) {
        guard sessions.count > Self.maxLiveSessions else { return }
        let overflow = sessions.count - Self.maxLiveSessions
        let victims = sessions.keys.filter { $0 != keep }.prefix(overflow)
        for victim in victims {
            Log.agent.notice("Pool de agentes lleno: se cierra el agente menos prioritario.")
            close(victim)
        }
    }
}
