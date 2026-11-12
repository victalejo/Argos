//
//  AgentNotifier.swift
//  ArgosiOS
//
//  Avisos de «Claude terminó» y «Claude espera tu permiso»: los de los agentes
//  persistentes y los de Claude Code dentro de las ventanas tmux (el flujo del terminal).
//
//  Sin servidores intermedios (Argos solo habla con TUS servidores) no hay push de
//  Apple: los avisos son notificaciones LOCALES. Con la app en segundo plano, iOS deja a
//  Argos refrescar de vez en cuando (BGAppRefreshTask; la frecuencia la decide iOS): en
//  cada refresco se lee el final del log de los agentes y el estado de Claude en tmux, y
//  se avisa de lo nuevo. Tocar un aviso abre su servidor (y su sesión, si la tiene).
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
    private static let claudeServersKey = "claude.servers"   // servidores con Claude en tmux
    private static let claudeSnapshotsKey = "claude.snapshots" // [servidor: snapshot JSON]

    private weak var hub: ServerHub?
    /// La app pasó de verdad por segundo plano (no solo por `.inactive`: Centro de control,
    /// Face ID…). Solo entonces lo guardado es más reciente que lo que hay en memoria.
    private var wasInBackground = false
    private let defaults = UserDefaults.standard

    // MARK: - Registro (antes de terminar de arrancar la app)

    func register(hub: ServerHub) {
        self.hub = hub
        UNUserNotificationCenter.current().delegate = ForegroundNotificationPresenter.shared
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

    /// Se vio Claude Code en una ventana tmux de este servidor: pide permiso de
    /// notificaciones (una vez) y lo apunta para revisarlo en segundo plano.
    func didSeeClaude(on server: Server) {
        var servers = Set(defaults.stringArray(forKey: Self.claudeServersKey) ?? [])
        guard servers.insert(server.id.uuidString).inserted else { return }
        defaults.set(Array(servers), forKey: Self.claudeServersKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// «Claude terminó / espera tu respuesta» en una ventana tmux. No se avisa de la
    /// sesión que hay en pantalla (`viewing`): ahí ya se ve.
    func postClaude(_ transitions: [ClaudeTransition], server: Server, viewing: String?) {
        for transition in transitions where transition.session != viewing {
            let content = UNMutableNotificationContent()
            content.title = transition.activity.label
            content.subtitle = "\(transition.session) · ventana \(transition.window) · \(server.name)"
            content.body = transition.activity == .waiting
                ? "Necesita permiso o una respuesta para continuar."
                : ClaudeDoneMessage.body(changedFiles: nil)
            content.sound = .default
            content.threadIdentifier = "claude-\(server.id.uuidString)-\(transition.session)"
            content.userInfo = NotificationRoute(
                serverID: server.id, session: transition.session, window: transition.window
            ).userInfo
            // Mismo identificador por ventana: un aviso nuevo reemplaza al anterior.
            let id = "\(Self.claudePrefix)\(server.id.uuidString)-\(transition.session)-\(transition.window)"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Al volver a primer plano: lo que se avisó en segundo plano pasa a ser lo último
    /// conocido, para que el sondeo de primer plano no lo avise otra vez.
    func didReturnToForeground() {
        guard let hub, wasInBackground else { return }
        wasInBackground = false
        let stored = claudeSnapshots()
        for (server, viewModel) in hub.loadedViewModels() {
            if let snapshot = stored[server.id.uuidString] { viewModel.adoptClaudeActivityBaseline(snapshot) }
        }
    }

    /// Al pasar a segundo plano: lo que el usuario ya vio no se avisa, y se pide el
    /// próximo refresco.
    func prepareForBackground() {
        guard let hub else { return }
        wasInBackground = true
        var snapshots = claudeSnapshots()
        for (server, viewModel) in hub.loadedViewModels() where viewModel.claudeActivity != .empty {
            snapshots[server.id.uuidString] = viewModel.claudeActivity
        }
        saveClaudeSnapshots(snapshots)
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
        guard !watchedServers(Self.serversKey).isEmpty || !watchedServers(Self.claudeServersKey).isEmpty else { return }
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

    /// Revisa los servidores apuntados (agentes persistentes y Claude en tmux) y avisa de
    /// lo nuevo. Una conexión por servidor, y solo de los que siguen existiendo.
    func check() async {
        guard let hub else { return }
        let withAgents = watchedServers(Self.serversKey)
        let withClaude = watchedServers(Self.claudeServersKey)
        var seen = seenBytes()
        var snapshots = claudeSnapshots()
        for server in hub.store.servers {
            let key = server.id.uuidString
            guard withAgents.contains(key) || withClaude.contains(key) else { continue }
            guard !Task.isCancelled else { break }
            let service = server.makeService()
            if withAgents.contains(key) {
                do {
                    let output = try await service.runAgentScript(PersistentAgentScript.snapshots())
                    let plan = AgentAttentionPlanner.notices(
                        snapshots: PersistentAgentScript.parseSnapshots(output), seenBytes: seen[key] ?? [:]
                    )
                    seen[key] = plan.seen
                    for notice in plan.notices { post(notice, server: server) }
                } catch {
                    Log.agent.notice("Avisos de agentes en segundo plano: \(error.userMessage, privacy: .public)")
                }
            }
            if withClaude.contains(key) {
                do {
                    let fresh = try await service.claudeActivity()
                    // Sin referencia previa no se sabe qué es nuevo: solo se toma nota.
                    if let previous = snapshots[key] {
                        postClaude(fresh.notableTransitions(since: previous), server: server, viewing: nil)
                    }
                    snapshots[key] = fresh
                } catch {
                    Log.agent.notice("Avisos de Claude en segundo plano: \(error.userMessage, privacy: .public)")
                }
            }
            await service.disconnect()
        }
        defaults.set(seen, forKey: Self.seenKey)
        saveClaudeSnapshots(snapshots)
        forgetRemovedServers(existing: Set(hub.store.servers.map(\.id.uuidString)))
    }

    /// Los servidores borrados dejan de revisarse.
    private func forgetRemovedServers(existing: Set<String>) {
        for key in [Self.serversKey, Self.claudeServersKey] {
            let kept = watchedServers(key).intersection(existing)
            defaults.set(Array(kept), forKey: key)
        }
        saveClaudeSnapshots(claudeSnapshots().filter { existing.contains($0.key) })
    }

    private func watchedServers(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func claudeSnapshots() -> [String: ClaudeActivitySnapshot] {
        guard let data = defaults.data(forKey: Self.claudeSnapshotsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ClaudeActivitySnapshot].self, from: data)) ?? [:]
    }

    private func saveClaudeSnapshots(_ snapshots: [String: ClaudeActivitySnapshot]) {
        defaults.set(try? JSONEncoder().encode(snapshots), forKey: Self.claudeSnapshotsKey)
    }

    /// Notificación tocada: se apunta el destino para que la interfaz lo abra.
    func open(_ route: NotificationRoute) {
        hub?.follow(route)
    }

    nonisolated static let claudePrefix = "claude-"

    /// «El CI de app pasó/falló» de los commits vigilados (con la app delante; en segundo
    /// plano iOS no deja sondear GitHub con la frecuencia necesaria).
    func postCI(_ results: [CIResult], server: Server) {
        guard !results.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        for result in results {
            let content = UNMutableNotificationContent()
            content.title = result.title
            content.subtitle = server.name
            content.body = result.body
            content.sound = .default
            content.threadIdentifier = "ci-\(result.watch.root)"
            let id = "ci-\(server.id.uuidString)-\(result.watch.root)-\(result.watch.sha ?? "")"
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    private func post(_ notice: AgentAttentionPlanner.Notice, server: Server) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = server.name
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.agentID
        content.userInfo = NotificationRoute(serverID: server.id).userInfo
        let request = UNNotificationRequest(identifier: "\(notice.agentID)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func seenBytes() -> [String: [String: Int]] {
        defaults.dictionary(forKey: Self.seenKey) as? [String: [String: Int]] ?? [:]
    }
}

/// Sin delegado, iOS no enseña las notificaciones con la app delante. Así se muestran
/// las de CI y las de Claude en tmux (que solo se generan para sesiones que no están en
/// pantalla); las de los agentes persistentes solo se generan en segundo plano.
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        return id.hasPrefix("ci-") || id.hasPrefix(AgentNotifier.claudePrefix) ? [.banner, .sound, .list] : []
    }

    /// Tocar un aviso lleva a su servidor y, si la tiene, a su sesión y ventana.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { AgentNotifier.shared.open(route) }
    }
}
