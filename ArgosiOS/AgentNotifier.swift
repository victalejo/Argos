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
//  se avisa de lo nuevo. Tocar un aviso abre su servidor y su sesión o, si es de un agente
//  persistente, el chat de ese agente.
//

import BackgroundTasks
import Foundation
import UIKit
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
    /// Destino pedido (atajo, aviso) antes de que la app registrara su `ServerHub`.
    private var routeBeforeRegistration: NotificationRoute?
    /// La app pasó de verdad por segundo plano (no solo por `.inactive`: Centro de control,
    /// Face ID…). Solo entonces lo guardado es más reciente que lo que hay en memoria.
    private var wasInBackground = false
    private let defaults = UserDefaults.standard

    // MARK: - Registro (antes de terminar de arrancar la app)

    func register(hub: ServerHub) {
        self.hub = hub
        if let route = routeBeforeRegistration {
            routeBeforeRegistration = nil
            hub.follow(route)
        }
        UNUserNotificationCenter.current().delegate = ForegroundNotificationPresenter.shared
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            MainActor.assumeIsolated { AgentNotifier.shared.handle(refresh) }
        }
    }

    /// Al crear o abrir un agente: apunta el servidor para revisarlo en segundo plano.
    /// El permiso de notificaciones NO se pide aquí (puede llegar desde una carga, no
    /// desde un toque): lo pide `requestAuthorizationFromUserAction()`.
    func didUseAgents(on server: Server) {
        var servers = Set(defaults.stringArray(forKey: Self.serversKey) ?? [])
        servers.insert(server.id.uuidString)
        defaults.set(Array(servers), forKey: Self.serversKey)
    }

    /// Se vio Claude Code en una ventana tmux de este servidor (lo detecta el sondeo):
    /// se apunta para revisarlo en segundo plano. Sin pedir permiso: es un sondeo.
    func didSeeClaude(on server: Server) {
        var servers = Set(defaults.stringArray(forKey: Self.claudeServersKey) ?? [])
        guard servers.insert(server.id.uuidString).inserted else { return }
        defaults.set(Array(servers), forKey: Self.claudeServersKey)
    }

    // MARK: - Permiso (siempre tras una acción del usuario)

    /// Pide el permiso de notificaciones si aún no se pidió. Llamar SOLO desde una
    /// acción del usuario (botón «Activar avisos», crear un agente, activar el indicador
    /// de Claude): iOS solo lo pregunta una vez y, pedido a destiempo, se suele denegar.
    /// Devuelve si los avisos quedan permitidos.
    @discardableResult
    func requestAuthorizationFromUserAction() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return Self.permission(settings.authorizationStatus) != .denied
        }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.agent.error("No se pudo pedir el permiso de notificaciones: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Estado real del sistema para la hoja «Avisos».
    func readiness() async -> NotificationReadiness {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let refresh: BackgroundRefreshAvailability = switch UIApplication.shared.backgroundRefreshStatus {
        case .available: .available
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
        return NotificationReadiness(
            permission: Self.permission(settings.authorizationStatus),
            alertsEnabled: settings.alertSetting != .disabled || settings.notificationCenterSetting == .enabled,
            backgroundRefresh: refresh,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func permission(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .quiet
        @unknown default: return .denied
        }
    }

    /// Al abrir una sesión: retira del Centro de notificaciones sus avisos de Claude (ya
    /// no hacen falta: el usuario la está mirando).
    func withdrawDelivered(serverID: Server.ID, session: String) {
        let thread = Self.claudeThread(serverID: serverID, session: session)
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    private static func claudeThread(serverID: Server.ID, session: String) -> String {
        "claude-\(serverID.uuidString)-\(session)"
    }

    /// «Claude terminó / espera tu respuesta» en una ventana tmux. Quien llama ya quitó
    /// lo que está a la vista (`ClaudeNoticeSuppression`).
    func postClaude(_ transitions: [ClaudeTransition], server: Server) {
        for transition in transitions {
            let content = UNMutableNotificationContent()
            content.title = transition.activity.label
            content.subtitle = String(localized: "\(transition.session) · ventana \(transition.window) · \(server.name)")
            content.body = transition.activity == .waiting
                ? String(localized: "Necesita permiso o una respuesta para continuar.")
                : ClaudeDoneMessage.body(changedFiles: nil)
            content.sound = .default
            content.threadIdentifier = Self.claudeThread(serverID: server.id, session: transition.session)
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
        // Lo cierra quien llegue antes: el trabajo al terminar o el sistema al agotar el
        // tiempo (iOS penaliza a la app si no se completa a tiempo).
        let completion = CompletionOnce { task.setTaskCompleted(success: $0) }
        let work = Task { @MainActor in
            await self.check()
            completion.complete(success: !Task.isCancelled)
        }
        // Se completa en el propio aviso, sin esperar a que `check()` atienda la
        // cancelación. La tarea se registró con la cola principal, así que suele llegar
        // en el hilo principal; si no, se salta a él.
        task.expirationHandler = {
            let expire: @MainActor @Sendable () -> Void = {
                Log.agent.notice("Se agotó el tiempo de la comprobación en segundo plano")
                work.cancel()
                completion.complete(success: false)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { expire() }
            } else {
                Task { @MainActor in expire() }
            }
        }
    }

    /// Lo leído de un servidor en segundo plano (`nil` en lo que falló o no tocaba).
    private struct ServerReading: Sendable {
        var agentOutput: String?
        var claude: ClaudeActivitySnapshot?
    }

    /// Revisa los servidores apuntados (agentes persistentes y Claude en tmux) y avisa de
    /// lo nuevo. En paralelo y con plazo por servidor (`BackgroundCheckPlanner`): uno
    /// inalcanzable no agota el tiempo de los demás. Lo de cada servidor se guarda en
    /// cuanto llega, por si el sistema corta la tarea antes del final.
    func check() async {
        guard let hub else { return }
        let items = BackgroundCheckPlanner.items(
            servers: hub.store.servers,
            agentKeys: watchedServers(Self.serversKey),
            claudeKeys: watchedServers(Self.claudeServersKey)
        )
        let targets = items.compactMap { item in hub.store.server(withID: item.serverID).map { ($0, item) } }
        await withTaskGroup(of: Void.self) { group in
            for (server, item) in targets {
                group.addTask { await self.check(server, item: item) }
            }
        }
        forgetRemovedServers(existing: Set(hub.store.servers.map(\.id.uuidString)))
    }

    private func check(_ server: Server, item: BackgroundCheckPlanner.Item) async {
        let service = server.makeService()
        // Sondeo de fondo: no se salta la espera tras un fallo ni el cupo de canales.
        let reading = await Deadline.value(within: BackgroundCheckPlanner.perServerTimeout) {
            await ConnectionPriority.background { await Self.read(service, item: item) }
        }
        // Sin esperar: con una conexión colgada, el cierre tampoco respondería.
        Task { await service.disconnect() }
        guard let reading else {
            Log.agent.notice("El servidor \(server.name, privacy: .private) no respondió a tiempo en segundo plano")
            return
        }
        apply(reading, server: server)
    }

    /// Lecturas de un servidor (fuera del hilo principal; se aplican después).
    private nonisolated static func read(
        _ service: any SSHServicing, item: BackgroundCheckPlanner.Item
    ) async -> ServerReading {
        var reading = ServerReading()
        if item.checkAgents {
            do {
                reading.agentOutput = try await service.runAgentScript(PersistentAgentScript.snapshots())
            } catch {
                Log.agent.notice("Avisos de agentes en segundo plano: \(error.userMessage, privacy: .private)")
            }
        }
        if item.checkClaude, !Task.isCancelled {
            do {
                reading.claude = try await service.claudeActivity()
            } catch {
                Log.agent.notice("Avisos de Claude en segundo plano: \(error.userMessage, privacy: .private)")
            }
        }
        return reading
    }

    /// Avisa de lo nuevo y lo guarda ya (lectura-modificación-escritura en el hilo
    /// principal: las de otros servidores no se pisan).
    private func apply(_ reading: ServerReading, server: Server) {
        let key = server.id.uuidString
        if let output = reading.agentOutput {
            var seen = seenBytes()
            let snapshots = PersistentAgentScript.parseSnapshots(output)
            let plan = AgentAttentionPlanner.notices(snapshots: snapshots, seenBytes: seen[key] ?? [:])
            seen[key] = plan.seen
            defaults.set(seen, forKey: Self.seenKey)
            let folders = Dictionary(snapshots.map { ($0.id, $0.workingDirectory) }, uniquingKeysWith: { first, _ in first })
            for notice in plan.notices { post(notice, server: server, workingDirectory: folders[notice.agentID]) }
        }
        if let fresh = reading.claude {
            var snapshots = claudeSnapshots()
            // Sin referencia previa no se sabe qué es nuevo: solo se toma nota.
            if let previous = snapshots[key] {
                postClaude(fresh.notableTransitions(since: previous), server: server)
            }
            snapshots[key] = fresh
            saveClaudeSnapshots(snapshots)
        }
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

    /// Notificación tocada (o atajo «Abrir proyecto»): se apunta el destino para que la
    /// interfaz lo abra. `ServerHub.follow` lo retiene si la app está bloqueada.
    func open(_ route: NotificationRoute) {
        guard let hub else {
            routeBeforeRegistration = route
            return
        }
        hub.follow(route)
    }

    nonisolated static let claudePrefix = "claude-"

    /// «El CI de app pasó/falló» de los commits vigilados (con la app delante; en segundo
    /// plano iOS no deja sondear GitHub con la frecuencia necesaria).
    func postCI(_ results: [CIResult], server: Server) {
        guard !results.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
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

    /// «La cola de encargos se frenó por el presupuesto» (una vez por bloqueo, también entre
    /// arranques: lo recuerda `ClaudeLimitAlertLedger`). Tocarlo abre el proyecto.
    func postBudget(_ blocks: [ClaudeBudgetBlock], server: Server, projects: [Project]) {
        for block in blocks where ClaudeLimitAlertLedger.claim("\(server.id.uuidString)-budget-\(block.id)") {
            let project = projects.first { ClaudeUsageProjects.key(forPath: $0.path) == block.projectKey }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Encargos en pausa por presupuesto")
            content.subtitle = "\(project?.name ?? ClaudeUsageProjects.fallbackName(block.projectKey)) · \(server.name)"
            content.body = block.message()
            content.sound = .default
            content.threadIdentifier = "budget-\(server.id.uuidString)"
            content.userInfo = NotificationRoute(serverID: server.id, projectPath: project?.path).userInfo
            let id = "budget-\(server.id.uuidString)-\(block.id)"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Tocarlo abre el chat de ese agente (en su proyecto), tras Face ID si está activo.
    private func post(_ notice: AgentAttentionPlanner.Notice, server: Server, workingDirectory: String?) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = server.name
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.agentID
        content.userInfo = NotificationRoute(
            serverID: server.id,
            projectPath: workingDirectory.flatMap { $0.isEmpty ? nil : $0 },
            agentID: notice.agentID
        ).userInfo
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
