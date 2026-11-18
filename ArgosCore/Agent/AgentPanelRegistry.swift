//
//  AgentPanelRegistry.swift
//  Argos
//
//  Registro, en ESTE dispositivo, de los ids de sesión de las conversaciones del panel
//  Agente del Mac que se lanzaron en cada servidor. Sirve para encontrar huérfanos de
//  forma inequívoca: un `claude` headless del panel cuyo id está aquí lo lanzó este
//  dispositivo; si ya no tiene una pestaña viva, se puede matar sin riesgo. Un claude de
//  otro dispositivo, uno interactivo de tmux o uno ajeno a Argos nunca está en el
//  registro (ni tiene la forma exacta, ver `ServerAgentInventory.panelSessionID`).
//

import Foundation

struct AgentPanelRegistry: Sendable {
    /// Ids que se recuerdan como mucho por servidor (los más recientes).
    static let maxEntries = 64

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ serverID: Server.ID) -> String { "agent.panel.sessions.\(serverID.uuidString)" }

    func sessionIDs(serverID: Server.ID) -> [String] {
        defaults.stringArray(forKey: key(serverID)) ?? []
    }

    func record(_ sessionID: String, serverID: Server.ID) {
        let current = sessionIDs(serverID: serverID).filter { $0 != sessionID }
        defaults.set(Array((current + [sessionID.lowercased()]).suffix(Self.maxEntries)), forKey: key(serverID))
    }

    func replace(_ sessionIDs: [String], serverID: Server.ID) {
        defaults.set(Array(sessionIDs.suffix(Self.maxEntries)), forKey: key(serverID))
    }

    func forget(serverID: Server.ID) {
        defaults.removeObject(forKey: key(serverID))
    }
}

/// Decide qué procesos del panel son huérfanos (lógica pura).
enum AgentPanelOrphans {
    struct Plan: Equatable, Sendable {
        /// Procesos a matar: lanzados por este dispositivo y sin pestaña viva.
        let orphans: [ServerAgentProcess]
        /// Registro resultante: lo que sigue vivo en pestañas + lo que se intenta matar
        /// (si sobreviviera, se reintenta en la próxima limpieza).
        let registry: [String]
    }

    static func plan(
        inventory: ServerAgentInventory,
        registered: [String],
        liveTabSessionIDs: Set<String>
    ) -> Plan {
        let registeredSet = Set(registered.map { $0.lowercased() })
        let live = Set(liveTabSessionIDs.map { $0.lowercased() })
        let orphans = inventory.agents.filter { agent in
            guard case .panel = agent.kind else { return false }
            return registeredSet.contains(agent.sessionID) && !live.contains(agent.sessionID)
        }
        let running = Set(inventory.agents.compactMap { agent -> String? in
            if case .panel = agent.kind { return agent.sessionID }
            return nil
        })
        // Se conservan: las de pestañas vivas y las registradas que aún corren.
        let registry = registered.map { $0.lowercased() }.filter { live.contains($0) || running.contains($0) }
        return Plan(orphans: orphans, registry: registry)
    }
}
