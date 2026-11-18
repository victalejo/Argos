//
//  BackgroundCheckPlanner.swift
//  ArgosCore
//
//  Planificación de la comprobación en segundo plano (avisos de agentes y de Claude en
//  tmux): qué servidores revisar y qué leer de cada uno. iOS da unos 30 s a un
//  BGAppRefreshTask; un servidor inalcanzable no puede gastarlos todos, así que los
//  servidores se revisan en paralelo y cada uno con su plazo (como Android). Pura.
//

import Foundation

enum BackgroundCheckPlanner {
    /// Plazo por servidor (conexión + lecturas). Por debajo de los ~30 s del sistema.
    static let perServerTimeout: Duration = .seconds(11)

    struct Item: Equatable, Sendable {
        let serverID: Server.ID
        let checkAgents: Bool
        let checkClaude: Bool
    }

    /// Servidores que siguen existiendo y están apuntados para alguna de las dos
    /// revisiones, en el orden de la lista. `agentKeys`/`claudeKeys` son UUID en texto
    /// (así se guardan en `UserDefaults`).
    static func items(
        servers: [Server], agentKeys: Set<String>, claudeKeys: Set<String>
    ) -> [Item] {
        servers.compactMap { server in
            let key = server.id.uuidString
            let agents = agentKeys.contains(key)
            let claude = claudeKeys.contains(key)
            guard agents || claude else { return nil }
            return Item(serverID: server.id, checkAgents: agents, checkClaude: claude)
        }
    }
}

/// Completa una tarea del sistema una sola vez, la cierre quien la cierre primero (el
/// trabajo al terminar o el `expirationHandler` al agotarse el tiempo).
@MainActor
final class CompletionOnce {
    private var completion: ((Bool) -> Void)?

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    var isCompleted: Bool { completion == nil }

    func complete(success: Bool) {
        guard let completion else { return }
        self.completion = nil
        completion(success)
    }
}
