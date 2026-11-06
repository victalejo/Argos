//
//  AgentSessionStore.swift
//  Argos
//
//  Pool de agentes de Claude Code por proyecto/sesión (`SessionHandle`), con VARIAS
//  conversaciones en pestañas por cada uno (como las ventanas del terminal). Mantiene
//  los agentes vivos aunque cambies de proyecto o de pestaña (Terminal/Archivos/Agente).
//

import Foundation
import Observation

/// Una conversación del panel de agente.
struct AgentTab: Identifiable {
    let id: UUID
    /// Número visible ("Conversación 2"), creciente por proyecto.
    let number: Int
    let session: ClaudeAgentSession

    /// Título: el inicio del primer mensaje del usuario, o "Conversación N".
    @MainActor var title: String {
        for item in session.state.items {
            if case .userText(let text) = item.kind {
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                return line.count > 28 ? String(line.prefix(27)) + "…" : line
            }
        }
        return "Conversación \(number)"
    }
}

@MainActor
@Observable
final class AgentSessionStore {

    private var tabsByHandle: [SessionHandle: [AgentTab]] = [:]
    private var selectedByHandle: [SessionHandle: UUID] = [:]
    private var counters: [SessionHandle: Int] = [:]
    /// Orden de creación global (para cerrar las más antiguas si se supera el tope).
    private var creationOrder: [UUID] = []

    /// Tope de agentes vivos a la vez EN TOTAL (cada uno es un `claude` remoto que ocupa
    /// ~0,5 GB en el servidor).
    static let maxLiveSessions = 6

    func tabs(for handle: SessionHandle) -> [AgentTab] {
        tabsByHandle[handle] ?? []
    }

    func selectedTab(for handle: SessionHandle) -> AgentTab? {
        let tabs = tabs(for: handle)
        return tabs.first { $0.id == selectedByHandle[handle] } ?? tabs.last
    }

    func select(_ tabID: UUID, for handle: SessionHandle) {
        selectedByHandle[handle] = tabID
    }

    /// Abre una conversación nueva (pestaña) y la selecciona.
    @discardableResult
    func newTab(
        for handle: SessionHandle,
        service: any SSHServicing,
        command: String,
        workingDirectory: String
    ) -> AgentTab {
        let number = (counters[handle] ?? 0) + 1
        counters[handle] = number
        let tab = AgentTab(
            id: UUID(),
            number: number,
            session: ClaudeAgentSession(service: service, command: command, workingDirectory: workingDirectory)
        )
        tabsByHandle[handle, default: []].append(tab)
        selectedByHandle[handle] = tab.id
        creationOrder.append(tab.id)
        evictIfNeeded(keeping: tab.id)
        return tab
    }

    /// Cierra una conversación (mata su `claude` remoto).
    func closeTab(_ tabID: UUID, for handle: SessionHandle) {
        guard var tabs = tabsByHandle[handle], let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].session.stop()
        tabs.remove(at: index)
        creationOrder.removeAll { $0 == tabID }
        tabsByHandle[handle] = tabs.isEmpty ? nil : tabs
        if selectedByHandle[handle] == tabID {
            selectedByHandle[handle] = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    /// Cierra todas las conversaciones de un proyecto (p. ej. al detenerlo).
    func closeAll(for handle: SessionHandle) {
        for tab in tabs(for: handle) { closeTab(tab.id, for: handle) }
        counters[handle] = nil
    }

    /// Cierra todos los agentes de un servidor (al eliminarlo/editarlo).
    func closeAll(forServer serverID: Server.ID) {
        for handle in tabsByHandle.keys where handle.serverID == serverID {
            closeAll(for: handle)
        }
    }

    var liveCount: Int { creationOrder.count }

    /// Si se supera el tope, cierra las conversaciones más antiguas (no la recién creada).
    private func evictIfNeeded(keeping keep: UUID) {
        while creationOrder.count > Self.maxLiveSessions,
              let victim = creationOrder.first(where: { $0 != keep }),
              let handle = tabsByHandle.first(where: { $0.value.contains { $0.id == victim } })?.key {
            Log.agent.notice("Tope de agentes alcanzado: se cierra la conversación más antigua.")
            closeTab(victim, for: handle)
        }
    }
}
