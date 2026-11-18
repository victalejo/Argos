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
//  agentes, túneles y avisos); reabrirla desde el Dock o el menú Ventana lo muestra tal
//  cual. Al salir (⌘Q) se detienen los agentes, se cierran los túneles y se desenganchan
//  los terminales (ver `ArgosAppDelegate`). Nunca se mata nada que corra en tmux.
//

import AppKit
import Foundation
import Observation

/// Servidor + servicio SSH para las hojas que operan sobre él («Enviar al iPhone»,
/// «Dispositivos autorizados», «Doctor»). El servicio se fija al abrir la hoja.
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

    /// Servidor con el que se construyó cada view model (para saber si hay que rehacerlo).
    @ObservationIgnored private var connectedAs: [Server.ID: Server] = [:]
    @ObservationIgnored private var poller: WorkspacePoller?
    @ObservationIgnored private let heartbeatSleep = HeartbeatSleepCoordinator()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var napActivity: NSObjectProtocol?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private(set) var isShuttingDown = false
    #if APPSTORE
    /// Servidores y huellas con iPhone/iPad por iCloud (solo el canal App Store).
    @ObservationIgnored private var cloudSync: CloudServerSync?
    #endif

    init(
        store: ServerStore = ServerStore(),
        terminalStore: TerminalSessionStore = TerminalSessionStore(),
        agentStore: AgentSessionStore = AgentSessionStore()
    ) {
        self.store = store
        self.terminalStore = terminalStore
        self.agentStore = agentStore
    }

    // MARK: - Arranque

    /// Idempotente: la ventana lo llama al aparecer (también al reabrirla).
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
    }

    private func startPolling() {
        // Mientras sondea, App Nap no debe dormir la app con la ventana oculta o cerrada:
        // si no, los sondeos se espaciaban minutos y los avisos llegaban tarde o nunca.
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Avisos de Claude Code en las sesiones remotas"
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

    /// Mantiene `vms` al día con `store.servers`: crea los de servidores nuevos, quita los
    /// de borrados y rehace los que cambiaron a dónde o cómo se conectan.
    func syncVMs() {
        let ids = Set(store.servers.map(\.id))
        for id in vms.keys where !ids.contains(id) {
            dropViewModel(for: id)
        }
        // Arranque perezoso: solo se CREAN. La carga se dispara para el servidor
        // seleccionado (`loadSelectedIfNeeded`) o al pulsar «Conectar».
        for server in store.servers {
            if vms[server.id] == nil {
                installViewModel(for: server)
            } else if let previous = connectedAs[server.id],
                      ServerEditImpact.requiresNewConnection(previous: previous, updated: server, secretChanged: false) {
                rebuildConnection(for: server)
            }
        }
        poller?.reconcile()
    }

    /// Conexión nueva para `server`: cierra sus terminales y agentes (deben engancharse
    /// con el servicio nuevo) y carga el view model nuevo.
    func rebuildConnection(for server: Server) {
        terminalStore.closeAll(forServer: server.id)
        agentStore.closeAll(forServer: server.id)
        let old = vms[server.id]
        installViewModel(for: server)
        if let old { Task { await old.service.disconnect() } }
        if let vm = vms[server.id] { Task { await vm.load() } }
        poller?.reconcile()
    }

    private func installViewModel(for server: Server) {
        vms[server.id] = SessionsViewModel(service: server.makeService())
        connectedAs[server.id] = server
        portRequests[server.id] = nil
    }

    private func dropViewModel(for id: Server.ID) {
        if let old = vms.removeValue(forKey: id) { Task { await old.service.disconnect() } }
        connectedAs[id] = nil
        portRequests[id] = nil
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
        let notifier = ClaudeActivityNotifier.shared
        if vm.claudeActivity != .empty { notifier.requestAuthorizationIfNeeded() }
        let viewing = selectedSession?.serverID == server.id ? selectedSession?.sessionID : nil
        notifier.notify(
            serverID: server.id, serverName: server.name, transitions: round.result.transitions,
            viewing: viewing, gitSummary: { vm.gitSummary(forSession: $0) }
        )
        notifier.notifyCI(round.result.ciResults, serverID: server.id, serverName: server.name)
        if let pending = round.result.portRequests {
            portRequestsModel(for: server.id, service: vm.service).absorb(pending)
        }
    }

    private func portRequestsModel(for id: Server.ID, service: any SSHServicing) -> PortForwardRequestsModel {
        if let existing = portRequests[id] { return existing }
        let model = PortForwardRequestsModel(service: service)
        portRequests[id] = model
        return model
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
        let finished = await Deadline.succeeds(within: timeout) { [weak self] in
            await self?.performShutdown()
            return true
        }
        if !finished { Log.store.notice("Salida: el cierre ordenado no terminó a tiempo.") }
        if let napActivity { ProcessInfo.processInfo.endActivity(napActivity) }
    }

    private func performShutdown() async {
        await agentStore.stopAll()
        terminalStore.closeAll()
        let services = vms.values.map(\.service)
        await withTaskGroup(of: Void.self) { group in
            for service in services {
                group.addTask { await service.disconnect() }
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
