//
//  ServerAgentActions.swift
//  Argos
//
//  Acciones de «Agentes en este servidor» sobre el inventario (`ServerAgentInventory`):
//  parar agentes (persistentes por su carpeta, del panel por PID verificado) e hibernar los
//  inactivos. Devuelven los ids que no se pudieron tratar (p. ej. un proceso atascado).
//

import Foundation

enum ServerAgentActions {

    /// Para `agents`. Los persistentes se pueden reanudar después.
    static func stop(_ agents: [ServerAgentProcess], service: any SSHServicing) async throws -> [String] {
        let persistent = agents.compactMap { agent -> String? in
            if case .persistent = agent.kind { return agent.sessionID }
            return nil
        }
        let panel = agents.compactMap { agent -> (pid: Int32, sessionID: String)? in
            if case .panel(let pid) = agent.kind { return (pid, agent.sessionID) }
            return nil
        }
        var failed: [String] = []
        if !persistent.isEmpty {
            let output = try await service.runAgentScript(ServerAgentInventory.stopPersistent(ids: persistent))
            failed = ServerAgentInventory.failures(in: output)
        }
        if !panel.isEmpty { _ = try await service.runAgentScript(ServerAgentInventory.stopPanel(panel)) }
        return failed
    }

    /// Hiberna `agents` si en el servidor siguen quietos desde hace `minIdleSeconds`.
    static func hibernate(_ agents: [ServerAgentProcess], minIdleSeconds: Int, service: any SSHServicing) async throws -> [String] {
        guard !agents.isEmpty else { return [] }
        let output = try await service.runAgentScript(
            ServerAgentInventory.hibernate(ids: agents.map(\.sessionID), minIdleSeconds: minIdleSeconds)
        )
        return ServerAgentInventory.failures(in: output)
    }

    /// Mensaje para los que no se pudieron parar (con su título si se conoce).
    static func failureMessage(_ failed: [String], inventory: ServerAgentInventory?) -> String? {
        guard !failed.isEmpty else { return nil }
        let names = failed.map { id in inventory?.agents.first { $0.sessionID == id }?.title ?? id }
        return "No se pudieron parar: \(names.joined(separator: ", ")). Inténtalo de nuevo; si sigue, reinicia el servidor."
    }
}
