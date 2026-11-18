//
//  ServerHub.swift
//  ArgosiOS
//
//  Estado compartido de la app de iPhone/iPad: los servidores (`ServerStore`), un
//  `SessionsViewModel` por servidor (lista de proyectos y sesiones) y los terminales
//  vivos. Reutilizar el view model mantiene UNA conexión SSH por servidor; reutilizar
//  el controlador hace que volver a un terminal sea instantáneo: al cambiar a Archivos,
//  Cambios o Agentes (o al girar) el terminal se aparca unos minutos en vez de cerrarse
//  (`TerminalKeepAlivePool`).
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ServerHub {
    let store: ServerStore
    /// Ignorado por Observation: se rellena perezosamente desde las vistas, y escribir
    /// estado observado durante `body` provoca invalidaciones en bucle.
    @ObservationIgnored private var viewModels: [Server.ID: SessionsViewModel] = [:]
    @ObservationIgnored private var terminals: [SessionHandle: TouchTerminalController] = [:]
    /// Cuáles están en pantalla y cuáles aparcados (y desde cuándo).
    @ObservationIgnored private var keepAlive = TerminalKeepAlivePool<SessionHandle>()
    @ObservationIgnored private var keepAliveSweep: Task<Void, Never>?
    /// Vistas que muestran cada terminal. Al girar o redimensionar, la vista nueva puede
    /// aparecer antes de que desaparezca la vieja: solo se aparca cuando no queda ninguna.
    @ObservationIgnored private var terminalViewers: [SessionHandle: Int] = [:]
    @ObservationIgnored private let reachability = NetworkReachability()
    /// Paso real por segundo plano (no por `.inactive`).
    @ObservationIgnored private var lifecycle = BackgroundTransitionTracker()
    @ObservationIgnored private var detachTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var agents: [String: (server: Server.ID, session: PersistentAgentSession)] = [:]
    /// Agentes que estaban enganchados al pasar a segundo plano (se reenganchan al volver).
    @ObservationIgnored private var suspendedAgents: [(server: Server.ID, session: PersistentAgentSession)] = []

    /// Destino pedido al tocar una notificación. Lo consume la vista que lo resuelve.
    var pendingRoute: NotificationRoute?
    @ObservationIgnored private var routeExpiry: Task<Void, Never>?
    /// Sesión que hay en pantalla: de esa no se avisa con la app delante.
    @ObservationIgnored private(set) var viewing: SessionHandle?
    /// Vistas que la muestran: al girar, la nueva aparece antes de que se vaya la vieja.
    @ObservationIgnored private var viewingCount = 0
    @ObservationIgnored private var activityPoll: Task<Void, Never>?
    /// Cambia al arrancar y al parar el sondeo: una respuesta que llega tarde no avisa.
    @ObservationIgnored private var pollGeneration = 0

    /// Sincronización de servidores y huellas con el Mac y otros iPhone/iPad (iCloud).
    @ObservationIgnored private(set) var cloudSync: CloudServerSync?

    init(store: ServerStore = ServerStore(), syncWithICloud: Bool = true) {
        self.store = store
        guard syncWithICloud else { return }
        let sync = CloudServerSync(store: store)
        // Borrado en otro dispositivo: limpiar lo de este (conexiones, secretos, clave).
        sync.onRemoteRemoval = { [weak self] server in self?.forgetLocally(server) }
        sync.start()
        cloudSync = sync
    }

    /// Vigila la red para reintentar en el acto los terminales caídos.
    func startNetworkMonitoring() {
        reachability.onRestored = { [weak self] in
            self?.terminals.values.forEach { $0.networkDidReturn() }
        }
        reachability.start()
    }

    // MARK: - Servidores

    /// Guarda un servidor nuevo o editado, con su secreto (contraseña o passphrase).
    func save(_ server: Server, secret: String?, isNew: Bool) throws {
        switch server.authMethod {
        case .password:
            try KeychainStore.setPassword(secret, for: server.id)
            KeychainStore.deletePassphrase(for: server.id)
            ImportedKeyStore.remove(for: server.id)
        case .key:
            try KeychainStore.setPassphrase(server.requiresPassphrase ? secret : nil, for: server.id)
            KeychainStore.deletePassword(for: server.id)
        }
        if isNew { store.add(server) } else { store.update(server) }
        disconnect(server.id)
    }

    /// Servidor del QR del Mac: guarda su clave dedicada y fija la huella de host key que
    /// verificó el Mac. Si ese servidor ya está (llegó por iCloud), le pone la clave en vez
    /// de duplicarlo.
    @discardableResult
    func importTransfer(_ transfer: ServerTransfer) throws -> Server {
        guard !transfer.conflictsWithTrustedHostKey() else {
            throw ServerTransfer.HostKeyConflictError(endpoint: "\(transfer.host):\(transfer.port)")
        }
        let existing = transfer.matchingServer(in: store.servers) { ImportedKeyStore.needsImport($0) }
        let id = existing?.id ?? UUID()
        let pem = Data(try transfer.privateKeyPEM().utf8)
        let path = try ImportedKeyStore.store(pem, for: id)
        var server = existing ?? Server(
            id: id,
            name: transfer.name,
            host: transfer.host,
            port: transfer.port,
            username: transfer.username,
            authMethod: .key,
            privateKeyPath: path
        )
        server.privateKeyPath = path
        server.requiresPassphrase = false // la clave dedicada del QR no lleva passphrase
        do {
            try save(server, secret: nil, isNew: existing == nil)
        } catch {
            ImportedKeyStore.remove(for: id) // el servidor no tenía clave antes del QR
            throw error
        }
        if let fingerprint = transfer.hostKeyFingerprint {
            TOFUHostKeyValidator.trustIfUnknown(fingerprint: fingerprint, host: transfer.host, port: transfer.port)
        }
        return server
    }

    /// Borra el servidor con TODO lo suyo: secretos, clave importada y conexiones.
    func remove(_ server: Server) {
        forgetLocally(server)
        store.remove(server)
    }

    /// Lo propio de este dispositivo de un servidor que ya no está.
    private func forgetLocally(_ server: Server) {
        disconnect(server.id)
        KeychainStore.deletePassword(for: server.id)
        KeychainStore.deletePassphrase(for: server.id)
        ImportedKeyStore.remove(for: server.id)
    }

    // MARK: - Sesiones

    func viewModel(for server: Server) -> SessionsViewModel {
        if let existing = viewModels[server.id] { return existing }
        let viewModel = SessionsViewModel(service: server.makeService())
        viewModels[server.id] = viewModel
        return viewModel
    }

    /// Aviso tocado: pide abrir su destino, si su servidor sigue existiendo.
    func follow(_ route: NotificationRoute) {
        routeExpiry?.cancel()
        guard store.server(withID: route.serverID) != nil else {
            pendingRoute = nil
            return
        }
        pendingRoute = route
        routeExpiry = Task { @MainActor [weak self] in await self?.expire(route) }
    }

    /// Olvida el destino si no se pudo abrir: el plazo corre desde que la conexión con su
    /// servidor se resolvió (no desde el toque; conectar tras volver de segundo plano
    /// puede tardar), con un tope. Que la app saltara a esa sesión minutos después, al
    /// reconectar, sería desconcertante.
    private func expire(_ route: NotificationRoute) async {
        let clock = ContinuousClock()
        let tapped = clock.now
        var settledAt: ContinuousClock.Instant?
        while pendingRoute == route {
            let now = clock.now
            if settledAt == nil, isSettled(route.serverID) { settledAt = now }
            if NotificationRouteExpiry.shouldExpire(elapsed: now - tapped, sinceSettled: settledAt.map { now - $0 }) {
                pendingRoute = nil
                return
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    /// La conexión con el servidor ya se resolvió (cargada o con un error a la vista).
    private func isSettled(_ serverID: Server.ID) -> Bool {
        guard let state = viewModels[serverID]?.state else { return false }
        switch state {
        case .idle, .verifying, .installing, .configuring, .loading: return false
        case .loaded, .tmuxMissing, .hostKeyChanged, .failed: return true
        }
    }

    /// View models ya creados, con su servidor tal como está guardado ahora.
    func loadedViewModels() -> [(server: Server, viewModel: SessionsViewModel)] {
        viewModels.compactMap { id, viewModel in
            store.server(withID: id).map { ($0, viewModel) }
        }
    }

    // MARK: - Estado de Claude en tmux

    /// Cada cuánto se lee el estado de Claude Code de los servidores conectados.
    private static let activityPollInterval: Duration = .seconds(5)

    /// Con la app delante: sondea el estado de Claude Code en las ventanas tmux de los
    /// servidores conectados (insignia en la lista y aviso al terminar o pedir permiso).
    /// Vive aquí y no en una vista porque en iPhone la lista de proyectos desaparece al
    /// entrar en el terminal, que es justo cuando hace falta.
    func startActivityPolling() {
        guard activityPoll == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        activityPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Una tarea por servidor: uno con la conexión colgada no retrasa a los demás.
                let polls = self.loadedViewModels().map { server, viewModel in
                    Task { @MainActor [weak self] in
                        let transitions = await viewModel.refreshClaudeActivity()
                        // Parado mientras respondía (paso a segundo plano): no se avisa.
                        guard let self, self.pollGeneration == generation else { return }
                        if viewModel.claudeActivity != .empty { AgentNotifier.shared.didSeeClaude(on: server) }
                        let viewing = self.viewing?.serverID == server.id ? self.viewing?.sessionID : nil
                        AgentNotifier.shared.postClaude(transitions, server: server, viewing: viewing)
                    }
                }
                for poll in polls { await poll.value }
                do { try await Task.sleep(for: Self.activityPollInterval) } catch { return }
            }
        }
    }

    func stopActivityPolling() {
        pollGeneration += 1
        activityPoll?.cancel()
        activityPoll = nil
    }

    // MARK: - Secretos

    private static let secretsMigratedKey = "keychain.sshSecrets.afterFirstUnlock"

    /// Una vez: pasa los secretos SSH ya guardados a la política que permite leerlos en
    /// segundo plano (ver `KeychainStore`). Si falla (dispositivo bloqueado), se
    /// reintenta la próxima vez que la app pase a primer plano.
    func migrateSecretAccessibilityIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.secretsMigratedKey) else { return }
        if KeychainStore.applyCurrentAccessibility(toSSHSecretsOf: store.servers.map(\.id)) {
            defaults.set(true, forKey: Self.secretsMigratedKey)
        }
    }

    /// Olvida la huella del servidor y reconecta (tras una reinstalación legítima).
    func forgetHostKey(of server: Server) {
        TOFUHostKeyValidator.forgetExplicitly(host: server.host, port: server.port)
        disconnect(server.id)
    }

    // MARK: - Sesión en pantalla

    func startViewing(_ handle: SessionHandle) {
        viewingCount = viewing == handle ? viewingCount + 1 : 1
        viewing = handle
    }

    func stopViewing(_ handle: SessionHandle) {
        guard viewing == handle else { return }
        viewingCount -= 1
        if viewingCount <= 0 {
            viewingCount = 0
            viewing = nil
        }
    }

    // MARK: - Terminales

    func terminal(for server: Server, sessionName: String) -> TouchTerminalController {
        let handle = SessionHandle(serverID: server.id, sessionID: sessionName)
        keepAlive = keepAlive.showing(handle)
        terminalViewers[handle, default: 0] += 1
        if let existing = terminals[handle] { return existing }
        let size = UserDefaults.standard.object(forKey: TerminalAppearance.fontSizeKey) as? Double
        let controller = TouchTerminalController(
            service: viewModel(for: server).service,
            sessionName: sessionName,
            fontSize: size.map { CGFloat($0) } ?? TerminalAppearance.defaultFontSize
        )
        terminals[handle] = controller
        sweepKeepAlive()   // con el nuevo puede sobrar un aparcado
        return controller
    }

    /// El terminal sale de la pantalla (otra pestaña, girar, volver a la lista): sigue
    /// vivo unos minutos por si se vuelve a él.
    func parkTerminal(server: Server.ID, sessionName: String) {
        let handle = SessionHandle(serverID: server, sessionID: sessionName)
        let viewers = max(0, (terminalViewers[handle] ?? 0) - 1)
        terminalViewers[handle] = viewers == 0 ? nil : viewers
        guard viewers == 0 else { return }
        keepAlive = keepAlive.parking(handle, at: .now)
        sweepKeepAlive()
    }

    /// Cierra (detach) el terminal de una sesión; la sesión tmux sigue viva.
    func closeTerminal(server: Server.ID, sessionName: String) {
        let handle = SessionHandle(serverID: server, sessionID: sessionName)
        keepAlive = keepAlive.removing(handle)
        terminalViewers[handle] = nil
        terminals.removeValue(forKey: handle)?.stop()
    }

    /// Cierra los aparcados caducados o sobrantes y programa la próxima limpieza.
    private func sweepKeepAlive() {
        for handle in keepAlive.evictions(at: .now) {
            Log.terminal.info("Se cierra un terminal aparcado de \(handle.sessionID, privacy: .public)")
            closeTerminal(server: handle.serverID, sessionName: handle.sessionID)
        }
        keepAliveSweep?.cancel()
        guard let next = keepAlive.nextExpiry else { return }
        keepAliveSweep = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
            self?.sweepKeepAlive()
        }
    }

    /// Reabre los PTY de un servidor (o de todos) que murieron con la suspensión.
    func reconnectTerminals(of serverID: Server.ID? = nil) {
        for (handle, controller) in terminals where serverID == nil || handle.serverID == serverID {
            if controller.needsReconnect { controller.reconnect() }
        }
    }

    /// Al pasar a segundo plano: detach limpio antes de que iOS congele la app. Se pide
    /// tiempo extra al sistema para que el cierre del canal llegue al servidor; si no,
    /// queda un cliente tmux fantasma que condiciona el tamaño de ventana de los demás.
    /// Los aparcados se cierran del todo; los que están en pantalla se reabren al volver.
    func suspendTerminals() {
        let (pool, dropped) = keepAlive.droppingParked()
        keepAlive = pool
        keepAliveSweep?.cancel()
        let parked = dropped.compactMap { terminals.removeValue(forKey: $0) }
        guard !terminals.isEmpty || !parked.isEmpty, detachTask == .invalid else { return }
        detachTask = UIApplication.shared.beginBackgroundTask(withName: "argos.detach") { [weak self] in
            MainActor.assumeIsolated { self?.endDetachTask() }
        }
        let controllers = Array(terminals.values) + parked
        Task { @MainActor [weak self] in
            for controller in controllers { await controller.stopAndWait() }
            self?.endDetachTask()
        }
    }

    private func endDetachTask() {
        guard detachTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(detachTask)
        detachTask = .invalid
    }

    // MARK: - Segundo plano y vuelta

    /// La escena pasó a segundo plano (no basta con `.inactive`).
    func didEnterBackground() {
        lifecycle.enteredBackground()
        stopActivityPolling()
        suspendTerminals()
        suspendAgents()
    }

    /// La escena vuelve a estar activa. Solo si se viene de segundo plano: se comprueba
    /// cada conexión compartida (la de antes puede estar muerta sin saberlo), se refresca
    /// la lista SIN vaciarla y se reabren terminales y agentes.
    func didBecomeActive() {
        startActivityPolling()
        guard lifecycle.becameActive() else { return }
        for (id, viewModel) in viewModels {
            Task { @MainActor [weak self] in
                await Self.revalidate(viewModel)
                self?.reconnectTerminals(of: id)
                self?.resumeAgents(of: id)
            }
        }
        // Terminales de servidores sin view model (no debería haberlos) y agentes sueltos.
        let known = Set(viewModels.keys)
        for handle in terminals.keys where !known.contains(handle.serverID) {
            reconnectTerminals(of: handle.serverID)
        }
    }

    /// Sondea la conexión con plazo y refresca. Con la lista cargada usa `refresh()`
    /// (no pasa por «Conectando…»); si no estaba cargada, carga desde cero.
    private static func revalidate(_ viewModel: SessionsViewModel) async {
        guard case .loaded = viewModel.state else {
            if !viewModel.state.isBusy, case .failed = viewModel.state { await viewModel.load() }
            return
        }
        // Sondeo con plazo corto; si no responde se descarta SOLO la compartida (sin cerrar
        // túneles ni terminales, que revisa su propio vigilante) y el refresco reconecta.
        if await !viewModel.service.checkConnectionNow() {
            Log.ssh.notice("Al volver de segundo plano la conexión no respondía: se reconecta")
        }
        await viewModel.refresh()
    }

    // MARK: - Agentes persistentes

    /// Sesión cliente del agente (reutilizada mientras dure la app).
    func agentSession(for info: PersistentAgentInfo, server: Server) -> PersistentAgentSession {
        if let existing = agents[info.id]?.session { return existing }
        let session = PersistentAgentSession(service: viewModel(for: server).service, info: info)
        agents[info.id] = (server.id, session)
        return session
    }

    func register(_ session: PersistentAgentSession, server: Server) {
        agents[session.id] = (server.id, session)
    }

    /// Sesiones de agente abiertas en esta ejecución (para los avisos).
    func agentSessions() -> [(Server.ID, PersistentAgentSession)] {
        agents.values.map { ($0.server, $0.session) }
    }

    /// Segundo plano: deja de leer los logs (los agentes siguen en el servidor).
    private func suspendAgents() {
        let attached = agents.values.filter(\.session.isAttached)
        suspendedAgents += attached.map { ($0.server, $0.session) }
        attached.forEach { $0.session.detach() }
    }

    /// Reengancha los agentes de un servidor (tras comprobar su conexión).
    private func resumeAgents(of serverID: Server.ID) {
        let resumed = suspendedAgents.filter { $0.server == serverID }
        suspendedAgents.removeAll { $0.server == serverID }
        resumed.forEach { $0.session.attach() }
    }

    private func disconnect(_ serverID: Server.ID) {
        for (id, entry) in agents where entry.server == serverID {
            entry.session.detach()
            agents.removeValue(forKey: id)
        }
        suspendedAgents.removeAll { $0.server == serverID }
        for handle in terminals.keys where handle.serverID == serverID {
            closeTerminal(server: serverID, sessionName: handle.sessionID)
        }
        if let viewModel = viewModels.removeValue(forKey: serverID) {
            Task { await viewModel.service.disconnect() }
        }
    }
}
