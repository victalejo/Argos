//
//  AppModelLifecycleTests.swift
//  ArgosTests
//
//  Ciclo de vida del modelo único del Mac: cambios de servidor que llegan de otro
//  dispositivo, guardado con el Llavero fallando, selección tras borrar, salida con
//  pasos colgados, avisos de la sesión mirada, vueltas canceladas a medias y la
//  respuesta a `applicationShouldTerminate`.
//

import Foundation
import Testing
@testable import Argos

/// Secretos en memoria (y uno que falla al guardar).
@MainActor
final class MemorySecrets: ServerSecretStoring {
    var values: [Server.ID: String] = [:]
    var failsOnStore = false

    struct Failure: LocalizedError {
        var errorDescription: String? { "El Llavero no aceptó el secreto." }
    }

    func secret(for server: Server) -> String? { values[server.id] }

    func store(_ secret: String?, for server: Server) throws {
        if failsOnStore { throw Failure() }
        values[server.id] = secret
    }

    func removeAll(for serverID: Server.ID) { values[serverID] = nil }
}

@MainActor
@Suite("Modelo de la app: servidores", .serialized)
struct AppModelServerTests {

    private func makeModel(secrets: MemorySecrets? = nil) throws -> (ArgosAppModel, URL) {
        let secrets = secrets ?? MemorySecrets()
        let dir = try LocalShell.makeTemporaryDirectory()
        let store = ServerStore(storeURL: dir.appendingPathComponent("servers.json"))
        let model = ArgosAppModel(store: store, secrets: secrets, makeService: { _ in MockSSHService() })
        return (model, dir)
    }

    private func server(_ name: String, host: String = "a.example") -> Server {
        Server(name: name, host: host, username: "ana")
    }

    @Test("Un cambio de host llegado de otro dispositivo sin nada abierto reconecta solo")
    func remoteChangeWithoutWorkRebuilds() throws {
        let (model, dir) = try makeModel()
        defer { LocalShell.remove(dir) }
        var original = server("dev")
        model.store.add(original)
        model.syncVMs()
        let before = try #require(model.vms[original.id])
        let epoch = model.connectionEpochs[original.id]

        original.host = "b.example"
        model.store.replaceAll([original])
        model.syncVMs()
        #expect(model.vms[original.id] !== before)
        #expect(model.connectionEpochs[original.id] != epoch)
        #expect(model.pendingRemoteChanges.isEmpty)
    }

    @Test("Con terminales o agentes abiertos se aplaza y se ofrece «Reconectar»")
    func remoteChangeWithWorkIsDeferred() throws {
        let (model, dir) = try makeModel()
        defer { LocalShell.remove(dir) }
        model.liveWorkProbe = { _ in true }
        var original = server("dev")
        model.store.add(original)
        model.syncVMs()
        let before = try #require(model.vms[original.id])

        original.host = "b.example"
        model.store.replaceAll([original])
        model.syncVMs()
        #expect(model.vms[original.id] === before)
        #expect(model.pendingRemoteChanges == [original.id])

        model.applyRemoteChange(for: original.id)
        #expect(model.vms[original.id] !== before)
        #expect(model.pendingRemoteChanges.isEmpty)
    }

    @Test("Cambiar solo el nombre (en otro dispositivo) no reconecta")
    func remoteRenameKeepsConnection() throws {
        let (model, dir) = try makeModel()
        defer { LocalShell.remove(dir) }
        var original = server("dev")
        model.store.add(original)
        model.syncVMs()
        let before = try #require(model.vms[original.id])
        original.name = "Desarrollo"
        model.store.replaceAll([original])
        model.syncVMs()
        #expect(model.vms[original.id] === before)
    }

    @Test("Si el Llavero falla al guardar, no se guarda nada")
    func keychainFailureSavesNothing() throws {
        let secrets = MemorySecrets()
        let (model, dir) = try makeModel(secrets: secrets)
        defer { LocalShell.remove(dir) }
        secrets.failsOnStore = true
        let fresh = server("nuevo")
        #expect(throws: MemorySecrets.Failure.self) {
            try model.save(fresh, secret: "x", isNew: true)
        }
        #expect(model.store.servers.isEmpty)
        #expect(model.vms.isEmpty)

        secrets.failsOnStore = false
        try model.save(fresh, secret: "x", isNew: true)
        var renamed = fresh
        renamed.name = "renombrado"
        secrets.failsOnStore = true
        #expect(throws: MemorySecrets.Failure.self) {
            try model.save(renamed, secret: "otro", isNew: false)
        }
        #expect(model.store.servers.map(\.name) == ["nuevo"])
    }

    @Test("Guardar un servidor que se borró en otro dispositivo no lo resucita")
    func savingDeletedServerFails() throws {
        let (model, dir) = try makeModel()
        defer { LocalShell.remove(dir) }
        let gone = server("borrado")
        #expect(throws: ServerNoLongerExistsError.self) {
            try model.save(gone, secret: nil, isNew: false)
        }
        #expect(model.store.servers.isEmpty)
    }

    @Test("Olvidar un servidor corrige la selección")
    func forgetFixesSelection() throws {
        let (model, dir) = try makeModel()
        defer { LocalShell.remove(dir) }
        let first = server("uno"), second = server("dos")
        model.store.add(first)
        model.store.add(second)
        model.syncVMs()
        model.selectedServerID = first.id
        model.selectedSession = SessionHandle(serverID: first.id, sessionID: "web")
        model.delete(first)
        #expect(model.selectedServerID == second.id)
        #expect(model.selectedSession == nil)
        #expect(model.vms[first.id] == nil)
    }
}

@MainActor
@Suite("Modelo de la app: salida y avisos")
struct AppModelQuitAndNoticeTests {

    @Test("El cierre ordenado termina en plazo aunque un paso se cuelgue")
    func shutdownRespectsDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        let finished = await ShutdownRunner.run(within: .milliseconds(150)) {
            // Un `disconnect()` o `stopAll()` que nunca vuelve.
            try? await Task.sleep(for: .seconds(30))
        }
        #expect(!finished)
        #expect(clock.now - start < .seconds(2))
        #expect(await ShutdownRunner.run(within: .seconds(2)) {})
    }

    @Test("Solo se calla la sesión mirada con la app delante y la ventana a la vista")
    func viewingNeedsVisibleWindow() {
        let id = UUID()
        let handle = SessionHandle(serverID: id, sessionID: "web")
        #expect(NoticeViewing.viewingSession(selected: handle, serverID: id, activity: .active) == "web")
        for activity in [WorkspaceActivity.inactive, .hidden, .windowClosed, .asleep] {
            #expect(NoticeViewing.viewingSession(selected: handle, serverID: id, activity: activity) == nil)
        }
        #expect(NoticeViewing.viewingSession(selected: handle, serverID: UUID(), activity: .active) == nil)
    }

    @Test("Una vuelta cancelada durante la lectura no aplica nada ni avisa")
    func cancelledRoundDoesNothing() async {
        let mock = MockSSHService()
        mock.sessions = [TmuxSession(name: "web", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))]
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        mock.sessions.append(TmuxSession(name: "api", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0)))
        mock.onListSessions = { withUnsafeCurrentTask { $0?.cancel() } }
        let round = await Task { await vm.pollWorkspace() }.value
        #expect(round == nil)
        #expect(vm.sessions.map(\.name) == ["web"])
    }

    private func coordinator(
        work: QuitWorkInProgress,
        systemEnding: Bool = false,
        confirms: Bool,
        log: TerminationLog
    ) -> TerminationCoordinator {
        TerminationCoordinator(
            workInProgress: { work },
            isSystemSessionEnding: { systemEnding },
            confirm: { _ in log.confirmations += 1; return confirms },
            shutdown: { log.shutdowns += 1 },
            reply: { log.replies.append($0) }
        )
    }

    @Test("Cancelar la salida no la deja a medias y se puede volver a intentar")
    func cancelLeavesNoTermination() async {
        let log = TerminationLog()
        let busy = QuitWorkInProgress(busyAgents: 1, runningSyncs: 0)
        let cancelling = coordinator(work: busy, confirms: false, log: log)
        #expect(cancelling.shouldTerminate() == .cancel)
        #expect(!cancelling.isTerminating)
        #expect(log.shutdowns == 0)
    }

    @Test("Se responde una sola vez aunque se pida salir dos veces")
    func singleReply() async {
        let log = TerminationLog()
        let quitting = coordinator(work: QuitWorkInProgress(busyAgents: 0, runningSyncs: 0), confirms: true, log: log)
        #expect(quitting.shouldTerminate() == .later)
        #expect(quitting.shouldTerminate() == .later)
        for _ in 0..<20 { await Task.yield() }
        #expect(log.shutdowns == 1)
        #expect(log.replies == [true])
        #expect(log.confirmations == 0)
    }

    @Test("Al cerrar sesión o apagar no se pregunta")
    func systemShutdownSkipsConfirmation() async {
        let log = TerminationLog()
        let busy = QuitWorkInProgress(busyAgents: 2, runningSyncs: 1)
        let quitting = coordinator(work: busy, systemEnding: true, confirms: false, log: log)
        #expect(quitting.shouldTerminate() == .later)
        for _ in 0..<20 { await Task.yield() }
        #expect(log.confirmations == 0)
        #expect(log.replies == [true])
    }
}

@MainActor
final class TerminationLog {
    var confirmations = 0
    var shutdowns = 0
    var replies: [Bool] = []
}

@MainActor
@Suite("Reconexión: fallos inmediatos y servicios retirados")
struct ReconnectEdgeTests {

    @Test("Un reintento que falla al instante con el mismo mensaje sigue contando hasta el tope")
    func immediateRepeatedFailure() async {
        let reconnect = TerminalReconnectScheduler(
            policy: ReconnectPolicy(delays: [.milliseconds(1)], maxAttempts: 3),
            sleep: { _ in }
        )
        var attempts = 0
        // Cada reconexión vuelve a fallar en el acto con el mismo error.
        func fail() {
            reconnect.didFail(SSHConnectionError.connectionLost, isAsleep: false) {
                attempts += 1
                fail()
            }
        }
        fail()
        for _ in 0..<50 { await Task.yield() }
        #expect(attempts == 3)
        #expect(reconnect.gaveUp == .attemptsExhausted)
    }

    @Test("Con el servicio retirado no se reintenta")
    func retiredServiceGivesUp() async {
        let reconnect = TerminalReconnectScheduler(sleep: { _ in })
        var attempts = 0
        reconnect.didFail(SSHServiceRetiredError(host: "h"), isAsleep: false) { attempts += 1 }
        for _ in 0..<10 { await Task.yield() }
        #expect(attempts == 0)
        #expect(reconnect.gaveUp == .needsUserAction)
    }
}
