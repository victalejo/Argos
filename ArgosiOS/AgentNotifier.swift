//
//  AgentNotifier.swift
//  ArgosiOS
//
//  Avisos de los agentes persistentes: «Claude terminó» y «Claude espera tu permiso».
//
//  Sin servidores intermedios (Argos solo habla con TUS servidores) no hay push de
//  Apple: los avisos son notificaciones LOCALES. Con la app en segundo plano, iOS deja a
//  Argos refrescar de vez en cuando (BGAppRefreshTask; la frecuencia la decide iOS): en
//  cada refresco se lee el final del log de los agentes y se avisa de lo nuevo.
//

import BackgroundTasks
import Foundation
import UserNotifications

@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()
    static let taskIdentifier = "com.iaportafolio.argos.agents-refresh"

    private static let seenKey = "agents.seenBytes"          // [servidor: [agente: bytes]]
    private static let serversKey = "agents.servers"         // servidores con agentes

    private weak var hub: ServerHub?
    private let defaults = UserDefaults.standard

    // MARK: - Registro (antes de terminar de arrancar la app)

    func register(hub: ServerHub) {
        self.hub = hub
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            MainActor.assumeIsolated { AgentNotifier.shared.handle(refresh) }
        }
    }

    /// Al crear o abrir un agente: pide permiso de notificaciones (una vez) y apunta el
    /// servidor para revisarlo en segundo plano.
    func didUseAgents(on server: Server) {
        var servers = Set(defaults.stringArray(forKey: Self.serversKey) ?? [])
        servers.insert(server.id.uuidString)
        defaults.set(Array(servers), forKey: Self.serversKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Al pasar a segundo plano: lo que el usuario ya vio no se avisa, y se pide el
    /// próximo refresco.
    func prepareForBackground() {
        guard let hub else { return }
        var seen = seenBytes()
        for (serverID, session) in hub.agentSessions() where session.receivedBytes > 0 {
            seen[serverID.uuidString, default: [:]][session.id] = max(
                seen[serverID.uuidString]?[session.id] ?? 0, session.receivedBytes
            )
        }
        defaults.set(seen, forKey: Self.seenKey)
        schedule()
    }

    private func schedule() {
        guard !(defaults.stringArray(forKey: Self.serversKey) ?? []).isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.agent.notice("No se pudo programar el refresco de agentes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Refresco

    private func handle(_ task: BGAppRefreshTask) {
        schedule() // el siguiente, pase lo que pase con este
        let work = Task { @MainActor in
            await self.check()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Revisa los agentes de los servidores apuntados y avisa de lo nuevo.
    func check() async {
        guard let hub else { return }
        let wanted = Set(defaults.stringArray(forKey: Self.serversKey) ?? [])
        var seen = seenBytes()
        for server in hub.store.servers where wanted.contains(server.id.uuidString) {
            guard !Task.isCancelled else { break }
            let service = server.makeService()
            defer { Task { await service.disconnect() } }
            guard let output = try? await service.runAgentScript(PersistentAgentScript.snapshots()) else { continue }
            let plan = AgentAttentionPlanner.notices(
                snapshots: PersistentAgentScript.parseSnapshots(output),
                seenBytes: seen[server.id.uuidString] ?? [:]
            )
            seen[server.id.uuidString] = plan.seen
            for notice in plan.notices { post(notice, server: server) }
        }
        defaults.set(seen, forKey: Self.seenKey)
    }

    private func post(_ notice: AgentAttentionPlanner.Notice, server: Server) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = server.name
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.agentID
        content.userInfo = ["agentID": notice.agentID, "serverID": server.id.uuidString]
        let request = UNNotificationRequest(identifier: "\(notice.agentID)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func seenBytes() -> [String: [String: Int]] {
        defaults.dictionary(forKey: Self.seenKey) as? [String: [String: Int]] ?? [:]
    }
}
