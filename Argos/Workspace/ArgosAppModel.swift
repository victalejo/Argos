//
//  ArgosAppModel.swift
//  Argos
//
//  Modelo ÚNICO de la app del Mac. Antes la ventana creaba como `@State` el almacén de
//  servidores, los view models, los terminales, los agentes y iCloud: dos ventanas
//  tenían dos `servers.json` en memoria que se pisaban (servidores duplicados con iCloud),
//  doble conexión y doble sondeo; y cerrar la ventana y reabrirla desde el Dock creaba un
//  estado nuevo mientras los `claude`, los clientes tmux y los túneles viejos seguían
//  vivos sin interfaz. Ahora vive en el delegado de la app y la ventana solo lo observa.
//
//  Al cerrar la ventana la app sigue viva con todo su estado (terminales enganchados,
//  agentes, túneles y avisos); reabrirla lo muestra tal cual. Al salir (⌘Q) se detienen
//  los agentes, se cierran los túneles y se desenganchan los terminales (ver
//  `ArgosAppDelegate`). Nunca se mata nada que corra en tmux.
//
//  Ventana y entradas externas (avisos, barra de menús): `ArgosAppModel+Window.swift`.
//  Altas, ediciones y bajas: `ArgosAppModel+Servers.swift`.
//

import AppKit
import Foundation
import Observation

/// Servidor + servicio SSH para las hojas que operan sobre él («Enviar al iPhone»,
/// «Dispositivos autorizados», «Doctor»). El servicio se fija al abrir la hoja; si el
/// servidor se borra o cambia de conexión, la hoja se cierra (`connectionEpochs`).
struct ServerSheetTarget: Identifiable {
    let server: Server
    let service: any SSHServicing
    var id: Server.ID { server.id }
}

/// Una solicitud de puerto de Claude pendiente de responder, con su servidor.
struct PendingPortRequest {
    let server: Server
    let model: PortForwardRequestsModel
    let request: PortForwardRequest
}

@MainActor
@Observable
final class ArgosAppModel {
    let store: ServerStore
    /// Un view model por servidor (se crea al añadir, se rehace si cambia la conexión).
    private(set) var vms: [Server.ID: SessionsViewModel] = [:]
    /// Sube cada vez que el view model de un servidor se crea, se rehace o se quita: las
    /// hojas abiertas con el servicio anterior se cierran al verlo cambiar.
    private(set) var connectionEpochs: [Server.ID: Int] = [:]
    /// Servidores cuya conexión cambió en OTRO dispositivo (iCloud) con terminales o agentes
    /// abiertos aquí: no se reconectan solos; la interfaz ofrece «Reconectar».
    private(set) var pendingRemoteChanges: Set<Server.ID> = []
    /// Pool persistente de terminales en vivo.
    let terminalStore: TerminalSessionStore
    /// Pool de agentes de Claude Code del panel «Agente».
    let agentStore: AgentSessionStore
    /// Solicitudes de puertos de Claude por servidor (las alimenta el sondeador).
    private(set) var portRequests: [Server.ID: PortForwardRequestsModel] = [:]

    // MARK: Selección (sobrevive a cerrar y reabrir la ventana)
    var selectedServerID: Server.ID?
    var selectedSession: SessionHandle?
    var detailModes: [SessionHandle: DetailMode] = [:]
    /// Hoja del Doctor pedida desde un menú (contextual o Ayuda).
    var doctorTarget: ServerSheetTarget?
    /// Hoja de un envío pedida desde la bandeja de atención (la abre la columna central).
    var requestedSync: ProjectSyncRequest?

    // MARK: Bandeja de atención (ver `ArgosAppModel+Attention.swift`)
    /// «Terminó» sin mirar y CI fallidos (lo demás se lee en vivo de su fuente).
    var attentionInbox = AttentionInbox()
    /// Último elemento abierto, para «Ir al siguiente que me necesita».
    @ObservationIgnored var lastAttentionID: String?

    @ObservationIgnored let secrets: any ServerSecretStoring
    @ObservationIgnored private let makeService: @MainActor (Server) -> any SSHServicing
    /// Servidor con el que se construyó cada view model (para saber si hay que rehacerlo).
    @ObservationIgnored private var connectedAs: [Server.ID: Server] = [:]
    @ObservationIgnored private(set) var poller: WorkspacePoller?
    @ObservationIgnored private let heartbeatSleep = HeartbeatSleepCoordinator()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var napActivity: NSObjectProtocol?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private(set) var isShuttingDown = false
    /// Solo para tests: sustituye la comprobación de terminales y agentes abiertos.
    @ObservationIgnored var liveWorkProbe: (@MainActor (Server.ID) -> Bool)?
    /// Abre la ventana principal (lo registra un `Commands` con `openWindow`).
    @ObservationIgnored var windowOpener: (@MainActor () -> Void)?
    #if APPSTORE
    /// Servidores y huellas con iPhone/iPad por iCloud (solo el canal App Store).
    @ObservationIgnored private var cloudSync: CloudServerSync?
    #endif

    init(
        store: ServerStore = ServerStore(),
        terminalStore: TerminalSessionStore = TerminalSessionStore(),
        agentStore: AgentSessionStore = AgentSessionStore(),
        secrets: any ServerSecretStoring = KeychainServerSecrets(),
        makeService: @escaping @MainActor (Server) -> any SSHServicing = { $0.makeService() }
    ) {
        self.store = store
        self.terminalStore = terminalStore
        self.agentStore = agentStore
        self.secrets = secrets
        self.makeService = makeService
    }

    // MARK: - Arranque

    /// Idempotente: lo llama el delegado al terminar de arrancar (y la ventana al aparecer).
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        #if APPSTORE
        startCloudSync()
        #endif
        syncVMs()
        observeServers()
        observeSleep()
        observeActivation()
        startPolling()
        connectNotificationRoutes()
        observeDockBadge()
        observers.append(NotificationCenter.default.addObserver(
            forName: AttentionSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockBadge() }
        })
    }

    private func startPolling() {
        // Mientras sondea, App Nap no debe dormir la app con la ventana oculta o cerrada:
        // si no, los sondeos se espaciaban minutos y los avisos llegaban tarde o nunca.
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: String(localized: "Avisos de Claude Code en las sesiones remotas")
        )
        let poller = WorkspacePoller(
            targets: { [weak self] in self?.pollTargets ?? [] },
            activity: { AppActivityProbe.current() },
            onRound: { [weak self] round in self?.handle(round) }
        )
        self.poller = poller
        poller.start()
    }

    private var pollTargets: [WorkspacePoller.Target] {
        store.servers.compactMap { server in vms[server.id].map { .init(server: server, viewModel: $0) } }
    }

    /// Sigue la lista viva de servidores (altas, ediciones y lo que llega de iCloud).
    private func observeServers() {
        withObservationTracking {
            _ = store.servers
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncVMs()
                self?.observeServers()
            }
        }
    }

    /// Reposo del Mac: pausa el latido de todos los servidores y, al despertar, sondea ya.
    private func observeSleep() {
        withObservationTracking {
            _ = SystemSleepMonitor.shared.isAsleep
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let asleep = SystemSleepMonitor.shared.isAsleep
                self.heartbeatSleep.apply(asleep: asleep, to: self.vms.values.map(\.service))
                if !asleep { self.poller?.nudge() }
                self.observeSleep()
            }
        }
    }

    /// Al volver la app delante, la siguiente vuelta no espera al intervalo lento.
    private func observeActivation() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poller?.nudge() }
            })
        }
    }

    // MARK: - View models

    /// Mantiene `vms` al día con `store.servers`. Lo que llega aquí sin pasar por `save`
    /// viene de otro dispositivo (iCloud): si cambió a dónde o cómo se conecta y hay
    /// terminales o agentes abiertos, NO se cierran sin avisar (`pendingRemoteChanges`).
    func syncVMs() {
        let ids = Set(store.servers.map(\.id))
        for id in vms.keys where !ids.contains(id) {
            dropViewModel(for: id)
        }
        // Arranque perezoso: solo se CREAN. La carga se dispara para el servidor
        // seleccionado (`loadSelectedIfNeeded`) o al pulsar «Conectar».
        for server in store.servers {
            guard vms[server.id] != nil, let previous = connectedAs[server.id] else {
                installViewModel(for: server, replacing: nil)
                continue
            }
            let changed = ServerEditImpact.requiresNewConnection(previous: previous, updated: server, secretChanged: false)
            if !changed {
                pendingRemoteChanges.remove(server.id)
            } else if hasLiveWork(on: server.id) {
                pendingRemoteChanges.insert(server.id)
            } else {
                rebuildConnection(for: server)
            }
        }
        poller?.reconcile()
    }

    /// Hay algo abierto que una conexión nueva cerraría (terminal o agente).
    func hasLiveWork(on serverID: Server.ID) -> Bool {
        if let liveWorkProbe { return liveWorkProbe(serverID) }
        return terminalStore.hasTerminals(forServer: serverID)
            || agentStore.allTabs.contains { $0.handle.serverID == serverID && $0.tab.session.isRunning }
    }

    /// «Reconectar» tras un cambio llegado de otro dispositivo.
    func applyRemoteChange(for serverID: Server.ID) {
        guard let server = store.server(withID: serverID) else { return }
        rebuildConnection(for: server)
    }

    /// Conexión nueva para `server`: cierra sus terminales y agentes (deben engancharse
    /// con el servicio nuevo), retira el servicio viejo y carga el view model nuevo.
    func rebuildConnection(for server: Server) {
        pendingRemoteChanges.remove(server.id)
        terminalStore.closeAll(forServer: server.id)
        agentStore.closeAll(forServer: server.id)
        let old = vms[server.id]
        installViewModel(for: server, replacing: old)
        if let old { Task { await old.service.retire() } }
        if let vm = vms[server.id] { Task { await vm.load() } }
        poller?.reconcile()
    }

    private func installViewModel(for server: Server, replacing old: SessionsViewModel?) {
        let vm = SessionsViewModel(service: makeService(server))
        // Mismo servidor (otras credenciales): un «terminó» que caiga en la reconstrucción
        // no se pierde por ser el primer sondeo del view model nuevo.
        if let old, let previous = connectedAs[server.id], previous.host == server.host, previous.port == server.port {
            vm.seedClaudeBaseline(from: old)
        }
        vms[server.id] = vm
        connectedAs[server.id] = server
        connectionEpochs[server.id, default: 0] += 1
        // Lo ya respondido no reaparece aunque su borrado remoto fallara.
        let handled = portRequests[server.id]?.handledPorts ?? []
        portRequests[server.id] = PortForwardRequestsModel(service: vm.service, handled: handled)
    }

    private func dropViewModel(for id: Server.ID) {
        if let old = vms.removeValue(forKey: id) { Task { await old.service.retire() } }
        connectedAs[id] = nil
        connectionEpochs[id, default: 0] += 1
        portRequests[id] = nil
        pendingRemoteChanges.remove(id)
        attentionInbox.forget(serverID: id)
    }

    /// Carga el servidor seleccionado si aún no se cargó (`.idle`).
    func loadSelectedIfNeeded() {
        guard let id = selectedServerID, let vm = vms[id], case .idle = vm.state else { return }
        Task { await vm.load() }
    }

    func sheetTarget(for server: Server) -> ServerSheetTarget? {
        vms[server.id].map { ServerSheetTarget(server: server, service: $0.service) }
    }

    // MARK: - Vueltas del sondeador

    private func handle(_ round: WorkspacePoller.Round) {
        let server = round.server
        let vm = round.viewModel
        // De un view model ya descartado solo cuentan los avisos de Claude que trae (el
        // nuevo parte de su estado y no los repetiría); un servidor borrado, nada.
        guard store.server(withID: server.id) != nil else { return }
        let isCurrent = vms[server.id] === vm
        let notifier = ClaudeActivityNotifier.shared
        if vm.claudeActivity != .empty { notifier.requestAuthorizationIfNeeded() }
        let viewing = NoticeViewing.viewingSession(
            selected: selectedSession, serverID: server.id, activity: AppActivityProbe.current()
        )
        notifier.notify(
            serverID: server.id, serverName: server.name, transitions: round.result.transitions,
            viewing: viewing, gitSummary: { vm.gitSummary(forSession: $0) }
        )
        attentionInbox.absorb(
            serverID: server.id, transitions: round.result.transitions,
            snapshot: vm.claudeActivity, ciResults: isCurrent ? round.result.ciResults : []
        )
        if let viewing { attentionInbox.markSeen(serverID: server.id, session: viewing) }
        guard isCurrent else { return }
        notifier.notifyCI(round.result.ciResults, serverID: server.id, serverName: server.name)
        if let pending = round.result.portRequests {
            portRequests[server.id]?.absorb(pending)
        }
    }

    /// La solicitud de puerto más antigua de cualquier servidor conectado.
    var pendingPortRequest: PendingPortRequest? {
        for server in store.servers {
            if let model = portRequests[server.id], let request = model.current {
                return PendingPortRequest(server: server, model: model, request: request)
            }
        }
        return nil
    }

    // MARK: - Salida

    /// Lo que se perdería al salir (para confirmar).
    var workInProgress: QuitWorkInProgress {
        QuitWorkInProgress(
            busyAgents: agentStore.allTabs.filter { $0.tab.session.isBusy }.count,
            runningSyncs: ProjectSyncCenter.shared.jobs.values.filter(\.isRunning).count
        )
    }

    /// Cierre ordenado (con plazo): detiene el sondeo y los agentes del panel, desengancha
    /// los terminales y cierra túneles y conexiones. Lo que corre en tmux sigue vivo.
    func shutdown(within timeout: Duration) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        poller?.stop()
        await ShutdownRunner.run(within: timeout) { [weak self] in
            await self?.performShutdown()
        }
        if let napActivity { ProcessInfo.processInfo.endActivity(napActivity) }
    }

    private func performShutdown() async {
        await agentStore.stopAll()
        terminalStore.closeAll()
        let services = vms.values.map(\.service)
        await withTaskGroup(of: Void.self) { group in
            for service in services {
                group.addTask { await service.retire() }
            }
        }
    }

    #if APPSTORE
    private func startCloudSync() {
        guard cloudSync == nil else { return }
        let sync = CloudServerSync(store: store)
        // Borrado en otro dispositivo: limpiar lo de este Mac (conexiones y secretos).
        sync.onRemoteRemoval = { [weak self] server in self?.forgetLocally(server) }
        sync.start()
        cloudSync = sync
    }
    #endif
}
