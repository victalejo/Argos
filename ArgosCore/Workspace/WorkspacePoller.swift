//
//  WorkspacePoller.swift
//  ArgosCore
//
//  Sondeador compartido de los servidores (Mac; listo para iPhone/iPad). Antes el bucle
//  colgaba de una vista y leía una copia congelada de la lista: un servidor añadido o
//  editado con la app abierta se quedaba sin avisos de Claude, sin insignias de git/CI y
//  sin refresco de sesiones hasta reiniciar.
//
//  - Una tarea por servidor, en paralelo: uno colgado no retrasa a los demás.
//  - Sigue SIEMPRE la lista viva: cada tarea vuelve a pedir su servidor y su view model
//    en cada vuelta (`targets`) y termina si ya no está o si cambió de view model;
//    `reconcile()` arranca las que falten (llámalo al cambiar la lista).
//  - Intervalo según la actividad de la app (`WorkspacePollPlan`); en reposo, pausa.
//  - Cada vuelta gasta un solo canal (`SessionsViewModel.pollWorkspace`), como fondo.
//

import Foundation

@MainActor
final class WorkspacePoller {

    /// Un servidor a sondear con su view model actual.
    struct Target {
        let server: Server
        let viewModel: SessionsViewModel
    }

    /// Resultado de una vuelta, para avisar (en la plataforma).
    struct Round {
        let server: Server
        let viewModel: SessionsViewModel
        let result: WorkspacePollRound
    }

    private let timing: WorkspacePollTiming
    private let targets: @MainActor () -> [Target]
    private let activity: @MainActor () -> WorkspaceActivity
    private let onRound: @MainActor (Round) -> Void

    private struct Worker {
        let token: ObjectIdentifier
        let task: Task<Void, Never>
    }

    private var workers: [Server.ID: Worker] = [:]
    private(set) var isRunning = false
    /// Sube con cada `nudge()`: las tareas lo comparan con el último que vieron.
    private var nudgeGeneration = 0
    /// Vueltas completadas por servidor (diagnóstico y tests).
    private(set) var roundCounts: [Server.ID: Int] = [:]

    init(
        timing: WorkspacePollTiming = .standard,
        targets: @escaping @MainActor () -> [Target],
        activity: @escaping @MainActor () -> WorkspaceActivity,
        onRound: @escaping @MainActor (Round) -> Void
    ) {
        self.timing = timing
        self.targets = targets
        self.activity = activity
        self.onRound = onRound
    }

    /// Servidores con tarea en marcha.
    var polledServerIDs: Set<Server.ID> { Set(workers.keys) }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reconcile()
    }

    func stop() {
        isRunning = false
        for worker in workers.values { worker.task.cancel() }
        workers.removeAll()
    }

    /// Ajusta las tareas a la lista actual (servidor nuevo, editado o borrado).
    func reconcile() {
        guard isRunning else { return }
        let wanted = Dictionary(
            targets().map { ($0.server.id, ObjectIdentifier($0.viewModel)) },
            uniquingKeysWith: { first, _ in first }
        )
        let plan = WorkspacePollPlan.reconcile(running: workers.mapValues(\.token), wanted: wanted)
        for id in plan.stop {
            workers.removeValue(forKey: id)?.task.cancel()
        }
        for id in plan.start {
            guard let token = wanted[id] else { continue }
            workers[id] = Worker(token: token, task: Task { [weak self] in
                await self?.run(serverID: id, token: token)
            })
        }
    }

    /// Adelanta la próxima vuelta de todos (la app vuelve delante, el equipo despierta).
    func nudge() {
        nudgeGeneration &+= 1
    }

    // MARK: - Bucle de un servidor

    private func run(serverID: Server.ID, token: ObjectIdentifier) async {
        let clock = ContinuousClock()
        var lastRound: ContinuousClock.Instant?
        var seenNudge = nudgeGeneration
        while !Task.isCancelled {
            guard let target = currentTarget(serverID, token: token) else { break }
            let nudged = seenNudge != nudgeGeneration
            if WorkspacePollPlan.isDue(
                lastRound: lastRound, now: clock.now, activity: activity(), nudged: nudged, timing: timing
            ) {
                seenNudge = nudgeGeneration
                lastRound = clock.now
                await poll(target)
            }
            do { try await Task.sleep(for: timing.tick) } catch { break }
        }
        // Terminó por su cuenta (servidor borrado o rehecho): deja sitio a la nueva.
        if workers[serverID]?.token == token, !Task.isCancelled {
            workers.removeValue(forKey: serverID)
            reconcile()
        }
    }

    private func currentTarget(_ id: Server.ID, token: ObjectIdentifier) -> Target? {
        targets().first { $0.server.id == id && ObjectIdentifier($0.viewModel) == token }
    }

    private func poll(_ target: Target) async {
        guard let result = await target.viewModel.pollWorkspace(WorkspacePollPlan.sections) else { return }
        guard !Task.isCancelled else { return }
        roundCounts[target.server.id, default: 0] += 1
        // El servidor pudo cambiar de nombre durante la vuelta: se avisa con el actual.
        let server = targets().first { $0.server.id == target.server.id }?.server ?? target.server
        onRound(Round(server: server, viewModel: target.viewModel, result: result))
    }
}
