//
//  CollapsedSessionGroups.swift
//  Argos
//
//  Qué grupos de sesiones ("grupo/nombre") están colapsados en la barra lateral, por
//  servidor, y qué servidores enteros. Persiste en UserDefaults para respetar la
//  preferencia entre reinicios.
//

import Foundation
import Observation

@MainActor
@Observable
final class CollapsedSessionGroups {
    static let shared = CollapsedSessionGroups()

    private static let defaultsKey = "collapsedSessionGroups"
    private static let serversDefaultsKey = "collapsedServers"

    @ObservationIgnored private let defaults: UserDefaults
    /// Claves "<servidor>/<grupo>" de los grupos colapsados.
    private var collapsed: Set<String>
    /// UUIDs de los servidores colapsados enteros (independiente de sus grupos).
    private var collapsedServers: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.collapsed = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        self.collapsedServers = Set(defaults.stringArray(forKey: Self.serversDefaultsKey) ?? [])
    }

    func isCollapsed(serverID: UUID, group: String) -> Bool {
        collapsed.contains(Self.key(serverID: serverID, group: group))
    }

    func toggle(serverID: UUID, group: String) {
        let key = Self.key(serverID: serverID, group: group)
        if collapsed.contains(key) {
            collapsed.remove(key)
        } else {
            collapsed.insert(key)
        }
        defaults.set(collapsed.sorted(), forKey: Self.defaultsKey)
    }

    func isServerCollapsed(_ serverID: UUID) -> Bool {
        collapsedServers.contains(serverID.uuidString)
    }

    func toggleServer(_ serverID: UUID) {
        let key = serverID.uuidString
        if collapsedServers.contains(key) {
            collapsedServers.remove(key)
        } else {
            collapsedServers.insert(key)
        }
        defaults.set(collapsedServers.sorted(), forKey: Self.serversDefaultsKey)
    }

    /// El grupo es el prefijo ANTES del primer '/', así que nunca contiene '/' y
    /// "<uuid>/<grupo>" es inequívoco.
    private static func key(serverID: UUID, group: String) -> String {
        "\(serverID.uuidString)/\(group)"
    }
}
