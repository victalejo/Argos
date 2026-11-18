//
//  WorkspacePollerTests.swift
//  ArgosTests
//
//  Sondeador compartido: planificación (intervalos, empujones, reposo), reconciliación
//  con la lista VIVA de servidores (alta, edición con conexión nueva, baja), paralelismo
//  (un servidor lento no frena a otro) y la vuelta del view model.
//

import Foundation
import Testing
@testable import Argos

@Suite("Sondeador: planificación")
struct WorkspacePollPlanTests {

    private let timing = WorkspacePollTiming.standard
    private let clock = ContinuousClock()

    @Test("Intervalo según la actividad; en reposo, pausa")
    func intervals() {
        #expect(timing.interval(for: .active) == .seconds(3))
        // Tapada detrás de otra app (lo habitual): unos 5 s, no 20.
        #expect(timing.interval(for: .inactive) == .seconds(5))
        #expect(timing.interval(for: .hidden) == .seconds(5))
        #expect(timing.interval(for: .windowClosed) == .seconds(20))
        #expect(timing.interval(for: .asleep) == nil)
    }

    @Test("La primera vuelta va enseguida; las siguientes esperan su intervalo")
    func dueAfterInterval() {
        let now = clock.now
        #expect(WorkspacePollPlan.isDue(lastRound: nil, now: now, activity: .windowClosed, nudged: false, timing: timing))
        #expect(!WorkspacePollPlan.isDue(lastRound: now - .seconds(2), now: now, activity: .active, nudged: false, timing: timing))
        #expect(WorkspacePollPlan.isDue(lastRound: now - .seconds(3), now: now, activity: .active, nudged: false, timing: timing))
        // Ventana cerrada: 10 s no bastan.
        #expect(!WorkspacePollPlan.isDue(lastRound: now - .seconds(10), now: now, activity: .windowClosed, nudged: false, timing: timing))
    }

    @Test("Un empujón adelanta la vuelta, salvo con el equipo dormido")
    func nudgeAndSleep() {
        let now = clock.now
        #expect(WorkspacePollPlan.isDue(lastRound: now, now: now, activity: .hidden, nudged: true, timing: timing))
        #expect(!WorkspacePollPlan.isDue(lastRound: nil, now: now, activity: .asleep, nudged: true, timing: timing))
    }

    @Test("Reconciliar: arranca los nuevos, para los borrados y rehace los de view model nuevo")
    func reconcile() {
        let plan = WorkspacePollPlan.reconcile(
            running: ["a": 1, "b": 2, "c": 3],
            wanted: ["a": 1, "b": 20, "d": 4]
        )
        #expect(plan.stop == ["b", "c"])
        #expect(plan.start == ["b", "d"])
    }

    @Test("Cada vuelta pide todo junto (un solo comando)")
    func sectionsAreGrouped() {
        #expect(WorkspacePollPlan.sections == Set(WorkspacePollSection.allCases))
    }
}

@MainActor
@Suite("Sondeador: lista viva de servidores", .serialized)
struct WorkspacePollerTests {

    /// Lista mutable que el sondeador consulta en cada vuelta.
    @MainActor
    final class Targets {
        var list: [WorkspacePoller.Target] = []
        var activity: WorkspaceActivity = .active
    }

    private static let fast = WorkspacePollTiming(
        active: .milliseconds(20), inactive: .milliseconds(20), hidden: .milliseconds(20),
        windowClosed: .milliseconds(20), tick: .milliseconds(5)
    )

    private func loadedTarget(_ name: String) async -> (WorkspacePoller.Target, MockSSHService) {
        let mock = MockSSHService()
        mock.sessions = [TmuxSession(name: "main", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))]
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        return (WorkspacePoller.Target(server: Server(name: name, host: "\(name).example", username: "u"), viewModel: vm), mock)
    }

    private func makePoller(_ targets: Targets, rounds: @escaping (WorkspacePoller.Round) -> Void = { _ in }) -> WorkspacePoller {
        WorkspacePoller(timing: Self.fast, targets: { targets.list }, activity: { targets.activity }, onRound: rounds)
    }

    /// Espera (con tope) a que se cumpla `condition`.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("Un servidor añadido con la app abierta empieza a sondearse")
    func addedServerIsPolled() async {
        let targets = Targets()
        let (first, _) = await loadedTarget("uno")
        targets.list = [first]
        let poller = makePoller(targets)
        poller.start()
        defer { poller.stop() }
        #expect(await eventually { (poller.roundCounts[first.server.id] ?? 0) >= 1 })

        let (second, mock) = await loadedTarget("dos")
        targets.list.append(second)
        poller.reconcile()
        #expect(await eventually { (poller.roundCounts[second.server.id] ?? 0) >= 2 })
        #expect(mock.healthResets == 1) // solo el `load()` explícito: el sondeo no levanta bloqueos
    }

    @Test("Un servidor borrado deja de sondearse aunque nadie llame a reconcile")
    func removedServerStops() async {
        let targets = Targets()
        let (target, _) = await loadedTarget("uno")
        targets.list = [target]
        let poller = makePoller(targets)
        poller.start()
        defer { poller.stop() }
        #expect(await eventually { poller.polledServerIDs.contains(target.server.id) })
        targets.list = []
        #expect(await eventually { poller.polledServerIDs.isEmpty })
    }

    @Test("Un servidor editado con conexión nueva se sondea con su view model nuevo")
    func rebuiltViewModelIsFollowed() async {
        let targets = Targets()
        let (old, _) = await loadedTarget("uno")
        targets.list = [old]
        var lastViewModel: ObjectIdentifier?
        let poller = makePoller(targets) { lastViewModel = ObjectIdentifier($0.viewModel) }
        poller.start()
        defer { poller.stop() }
        #expect(await eventually { lastViewModel == ObjectIdentifier(old.viewModel) })

        let (fresh, _) = await loadedTarget("uno")
        targets.list = [WorkspacePoller.Target(server: old.server, viewModel: fresh.viewModel)]
        #expect(await eventually { lastViewModel == ObjectIdentifier(fresh.viewModel) })
    }

    @Test("Con el equipo dormido no hay vueltas; al despertar, sí")
    func sleepPauses() async {
        let targets = Targets()
        targets.activity = .asleep
        let (target, _) = await loadedTarget("uno")
        targets.list = [target]
        let poller = makePoller(targets)
        poller.start()
        defer { poller.stop() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(poller.roundCounts[target.server.id] == nil)
        targets.activity = .active
        poller.nudge()
        #expect(await eventually { (poller.roundCounts[target.server.id] ?? 0) >= 1 })
    }

    @Test("Un servidor lento no retrasa a los demás")
    func slowServerDoesNotBlockOthers() async {
        let targets = Targets()
        let (slow, slowMock) = await loadedTarget("lento")
        let (quick, _) = await loadedTarget("rapido")
        // El listado del lento bloquea su hilo un buen rato (fuera del actor principal).
        slowMock.onListSessions = { Thread.sleep(forTimeInterval: 1.5) }
        targets.list = [slow, quick]
        let poller = makePoller(targets)
        poller.start()
        defer { poller.stop() }
        #expect(await eventually { (poller.roundCounts[quick.server.id] ?? 0) >= 3 })
        #expect((poller.roundCounts[slow.server.id] ?? 0) <= 1)
    }

    @Test("Detenido, no queda ninguna tarea")
    func stopCancelsAll() async {
        let targets = Targets()
        let (target, _) = await loadedTarget("uno")
        targets.list = [target]
        let poller = makePoller(targets)
        poller.start()
        poller.stop()
        #expect(poller.polledServerIDs.isEmpty)
        poller.reconcile()
        #expect(poller.polledServerIDs.isEmpty)
    }
}

@MainActor
@Suite("Sondeador: vuelta del view model")
struct SessionsViewModelPollTests {

    private func loaded(_ mock: MockSSHService) async -> SessionsViewModel {
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        return vm
    }

    @Test("Recoge sesiones nuevas, solicitudes de puertos y avisa de Claude tras el primer sondeo")
    func roundAbsorbsEverything() async throws {
        let mock = MockSSHService()
        mock.sessions = [TmuxSession(name: "web", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))]
        let vm = await loaded(mock)
        mock.claudeSnapshot = ClaudeActivitySnapshot(listPanesOutput: "2|working|%1|0|web")
        _ = await vm.pollWorkspace()

        mock.sessions.append(TmuxSession(name: "api", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0)))
        mock.claudeSnapshot = ClaudeActivitySnapshot(listPanesOutput: "-|done|%1|0|web")
        mock.portRequests = [PortForwardRequest(port: 3000, note: "", ageSeconds: 1)]
        let round = try #require(await vm.pollWorkspace())
        #expect(vm.sessions.map(\.name) == ["web", "api"])
        #expect(round.transitions == [ClaudeTransition(session: "web", window: 0, activity: .done)])
        #expect(round.portRequests?.map(\.port) == [3000])
    }

    @Test("Va como trabajo de fondo y sin cargar no sondea")
    func backgroundAndOnlyWhenLoaded() async {
        let mock = MockSSHService()
        let idle = SessionsViewModel(service: mock)
        #expect(await idle.pollWorkspace() == nil)

        let vm = await loaded(mock)
        var seen: ConnectionPriority?
        mock.onListSessions = { seen = ConnectionPriority.current }
        _ = await vm.pollWorkspace()
        #expect(seen == .background)
    }

    @Test("Un fallo de red conserva la lista")
    func networkFailureKeepsList() async {
        let mock = MockSSHService()
        mock.sessions = [TmuxSession(name: "web", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))]
        let vm = await loaded(mock)
        mock.listError = SSHConnectionError.connectionLost
        #expect(await vm.pollWorkspace() == nil)
        #expect(vm.sessions.map(\.name) == ["web"])
    }
}
