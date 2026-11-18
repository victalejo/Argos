//
//  PersistentAgentAttentionTracker.swift
//  Argos
//
//  Qué agentes persistentes necesitan al usuario en el Mac (lógica pura), a partir de
//  `PersistentAgentOverview`:
//   - Espera un permiso: mientras el log lo diga (se lee en vivo, no se recuerda).
//   - Terminó sin mirar: entra cuando su log CRECE y acaba en un `result`; sale al
//     mirarlo (pestaña enganchada), al elegirlo en la bandeja o si vuelve a trabajar.
//  La primera vuelta de cada servidor solo toma referencia: abrir Argos no inunda la
//  bandeja con lo que terminó mientras estaba cerrado.
//

import Foundation

struct PersistentAgentAttentionTracker: Equatable, Sendable {

    /// Un agente que necesita al usuario.
    struct Notice: Equatable, Hashable, Sendable {
        enum Kind: Equatable, Hashable, Sendable {
            case permission(tool: String)
            case finished(summary: String?, isError: Bool)
        }

        let serverID: Server.ID
        let agentID: String
        let title: String
        let workingDirectory: String
        let kind: Kind

        var id: String {
            switch kind {
            case .permission: return "persistent|\(serverID)|\(agentID)"
            case .finished: return "persistent-done|\(serverID)|\(agentID)"
            }
        }
    }

    /// Bytes del log ya vistos por servidor y agente.
    private(set) var seenBytes: [Server.ID: [String: Int]] = [:]
    /// «Terminó» sin mirar, por `Notice.id`.
    private(set) var unseenDone: [String: Notice] = [:]

    /// Una vuelta de un servidor. `viewing`: agentes con su pestaña enganchada ahora.
    mutating func absorb(serverID: Server.ID, agents: [PersistentAgentOverview], viewing: Set<String> = []) {
        guard let previous = seenBytes[serverID] else {
            seenBytes[serverID] = Dictionary(agents.map { ($0.id, $0.logBytes) }, uniquingKeysWith: { first, _ in first })
            return
        }
        var seen: [String: Int] = [:]
        for agent in agents {
            let notice = Self.finishedNotice(agent, serverID: serverID)
            if viewing.contains(agent.id) {
                seen[agent.id] = agent.logBytes
                unseenDone[notice.id] = nil
                continue
            }
            if !Self.isFinished(agent.attention), agent.attention != .undetermined {
                // Volvió a trabajar (o espera un permiso): ya no está «terminado».
                unseenDone[notice.id] = nil
            }
            // Un agente nuevo (creado tras la referencia) cuenta desde 0.
            let before = previous[agent.id] ?? 0
            guard agent.logBytes > before else {
                seen[agent.id] = max(before, agent.logBytes)
                continue
            }
            // Lo que no se pudo evaluar se deja SIN ver: la próxima vuelta lo reintenta.
            guard agent.attention != .undetermined else {
                seen[agent.id] = before
                continue
            }
            seen[agent.id] = agent.logBytes
            if Self.isFinished(agent.attention) { unseenDone[notice.id] = notice }
        }
        seenBytes[serverID] = seen
        let present = Set(agents.map(\.id))
        unseenDone = unseenDone.filter { $0.value.serverID != serverID || present.contains($0.value.agentID) }
    }

    /// Elegido en la bandeja o abierto en una pestaña.
    mutating func markSeen(serverID: Server.ID, agentID: String) {
        unseenDone = unseenDone.filter { $0.value.serverID != serverID || $0.value.agentID != agentID }
    }

    /// El servidor se borró o se desconectó.
    mutating func forget(serverID: Server.ID) {
        seenBytes[serverID] = nil
        unseenDone = unseenDone.filter { $0.value.serverID != serverID }
    }

    /// Lo que hay que mostrar ahora: permisos pendientes (salvo los de `excluding`, que la
    /// app ya enseña con datos más frescos) y lo terminado sin mirar.
    func notices(agents: [Server.ID: [PersistentAgentOverview]], excluding: Set<String> = []) -> [Notice] {
        var result: [Notice] = []
        for (serverID, list) in agents {
            for agent in list where agent.isAlive && !excluding.contains(agent.id) {
                if case .needsPermission(let tool) = agent.attention {
                    result.append(Notice(
                        serverID: serverID, agentID: agent.id, title: agent.meta.title,
                        workingDirectory: agent.meta.workingDirectory, kind: .permission(tool: tool)
                    ))
                }
            }
        }
        result += unseenDone.values.filter { !excluding.contains($0.agentID) }
        return result.sorted { $0.id < $1.id }
    }

    private static func isFinished(_ attention: AgentAttention) -> Bool {
        if case .finished = attention { return true }
        return false
    }

    private static func finishedNotice(_ agent: PersistentAgentOverview, serverID: Server.ID) -> Notice {
        let kind: Notice.Kind
        if case .finished(let summary, let isError) = agent.attention {
            kind = .finished(summary: summary, isError: isError)
        } else {
            kind = .finished(summary: nil, isError: false)
        }
        return Notice(
            serverID: serverID, agentID: agent.id, title: agent.meta.title,
            workingDirectory: agent.meta.workingDirectory, kind: kind
        )
    }
}
