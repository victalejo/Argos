//
//  PersistentAgentWatch.swift
//  Argos
//
//  Sondeo de FONDO de los agentes persistentes de los servidores conectados (los creados
//  en el iPhone, Android u otro Mac): alimenta la lista «En el servidor» del panel Agente
//  y la bandeja de atención (espera tu permiso / terminó). Un solo comando de solo lectura
//  por servidor y vuelta (`persistentAgentOverview`), marcado como fondo
//  (`ConnectionPriority.background`): nunca abre canales por agente ni insiste contra un
//  servidor caído. Más espaciado en los servidores sin agentes vivos.
//

import Foundation
import Observation

@MainActor
@Observable
final class PersistentAgentWatch {

    /// Último listado de cada servidor.
    private(set) var agents: [Server.ID: [PersistentAgentOverview]] = [:]
    private(set) var tracker = PersistentAgentAttentionTracker()

    /// Entre vueltas con algún agente vivo en el servidor.
    static let activeInterval: TimeInterval = 20
    /// Entre vueltas de un servidor sin agentes vivos.
    static let quietInterval: TimeInterval = 90

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRound: [Server.ID: Date] = [:]
    @ObservationIgnored private var inFlight: Set<Server.ID> = []
    /// Agentes con su pestaña enganchada (los da quien los muestra).
    @ObservationIgnored var viewing: () -> [Server.ID: Set<String>] = { [:] }

    var isRunning: Bool { task != nil }

    /// Empieza a sondear. `targets`: los servidores conectados y su servicio.
    func start(targets: @escaping @MainActor () -> [(Server.ID, any SSHServicing)]) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.round(targets())
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Las vueltas que tocan (según el intervalo de cada servidor).
    private func round(_ targets: [(Server.ID, any SSHServicing)], now: Date = Date()) async {
        let ids = Set(targets.map(\.0))
        for gone in agents.keys where !ids.contains(gone) { forget(serverID: gone) }
        await withTaskGroup(of: Void.self) { group in
            for (serverID, service) in targets where isDue(serverID, now: now) {
                group.addTask { await self.refresh(serverID: serverID, service: service, background: true) }
            }
        }
    }

    private func isDue(_ serverID: Server.ID, now: Date) -> Bool {
        guard let last = lastRound[serverID] else { return true }
        let anyAlive = agents[serverID]?.contains(where: \.isAlive) ?? false
        return now.timeIntervalSince(last) >= (anyAlive ? Self.activeInterval : Self.quietInterval)
    }

    /// Relee un servidor ya (al abrir el panel o tras una acción). Devuelve el listado, o
    /// `nil` si no se pudo leer (se conserva el anterior).
    @discardableResult
    func refresh(serverID: Server.ID, service: any SSHServicing, background: Bool = false) async -> [PersistentAgentOverview]? {
        guard !inFlight.contains(serverID) else { return agents[serverID] }
        inFlight.insert(serverID)
        defer { inFlight.remove(serverID) }
        lastRound[serverID] = Date()
        do {
            let list: [PersistentAgentOverview]
            if background {
                list = try await ConnectionPriority.background { try await service.persistentAgentOverview() }
            } else {
                list = try await service.persistentAgentOverview()
            }
            agents[serverID] = list
            tracker.absorb(serverID: serverID, agents: list, viewing: viewing()[serverID] ?? [])
            return list
        } catch {
            Log.agent.notice("No se pudieron leer los agentes persistentes: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func markSeen(serverID: Server.ID, agentID: String) {
        tracker.markSeen(serverID: serverID, agentID: agentID)
    }

    func forget(serverID: Server.ID) {
        agents[serverID] = nil
        lastRound[serverID] = nil
        tracker.forget(serverID: serverID)
    }

    /// Agentes de una carpeta (proyecto) de un servidor.
    func agents(serverID: Server.ID, folder: String) -> [PersistentAgentOverview] {
        (agents[serverID] ?? []).filter { AgentFolderMatch.same($0.meta.workingDirectory, folder) }
    }

    func overview(serverID: Server.ID, agentID: String) -> PersistentAgentOverview? {
        agents[serverID]?.first { $0.id == agentID }
    }
}
