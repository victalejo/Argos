//
//  AppModelLogicTests.swift
//  ArgosTests
//
//  Lógica pura del modelo de app: ¿hay que rehacer la conexión al guardar un servidor?,
//  qué hace ⌘R con cada servidor, la confirmación al salir, las ventanas del terminal y
//  la reconexión automática con `ReconnectPolicy`.
//

import Foundation
import Testing
@preconcurrency import Citadel
@testable import Argos

@Suite("Guardar un servidor: ¿conexión nueva?")
struct ServerEditImpactTests {

    private let base = Server(
        name: "dev", host: "dev.example", port: 22, username: "ana",
        authMethod: .key, privateKeyPath: "~/.ssh/id_ed25519"
    )

    @Test("Cambiar solo el nombre no interrumpe nada")
    func renameKeepsConnection() {
        var renamed = base
        renamed.name = "Desarrollo"
        #expect(!ServerEditImpact.requiresNewConnection(previous: base, updated: renamed, secretChanged: false))
    }

    @Test("Host, puerto, usuario, método, clave o secreto sí la necesitan")
    func connectionFieldsRebuild() {
        let edits: [(inout Server) -> Void] = [
            { $0.host = "otro.example" },
            { $0.port = 2222 },
            { $0.username = "root" },
            { $0.authMethod = .password },
            { $0.privateKeyPath = "~/.ssh/otra" },
            { $0.privateKeyBookmark = Data([1, 2, 3]) },
            { $0.requiresPassphrase = true },
        ]
        for edit in edits {
            var updated = base
            edit(&updated)
            #expect(ServerEditImpact.requiresNewConnection(previous: base, updated: updated, secretChanged: false))
        }
        #expect(ServerEditImpact.requiresNewConnection(previous: base, updated: base, secretChanged: true))
        #expect(ServerEditImpact.requiresNewConnection(previous: nil, updated: base, secretChanged: false))
    }

    @Test("Secreto: vacío y ausente son lo mismo")
    func secretComparison() {
        #expect(!ServerEditImpact.secretChanged(stored: nil, new: ""))
        #expect(!ServerEditImpact.secretChanged(stored: "x", new: "x"))
        #expect(ServerEditImpact.secretChanged(stored: "x", new: "y"))
        #expect(ServerEditImpact.secretChanged(stored: "x", new: nil))
    }
}

@Suite("⌘R y salir de la app")
struct RefreshAndQuitTests {

    @Test("⌘R relee los cargados, reintenta los fallidos y no conecta los perezosos")
    func refreshPlan() {
        #expect(RefreshPlan.action(for: .loaded([])) == .refresh)
        #expect(RefreshPlan.action(for: .failed("x")) == .load)
        #expect(RefreshPlan.action(for: .hostKeyChanged("x")) == .load)
        #expect(RefreshPlan.action(for: .tmuxMissing) == .load)
        #expect(RefreshPlan.action(for: .idle) == .skip)
        #expect(RefreshPlan.action(for: .loading) == .skip)
        #expect(RefreshPlan.action(for: .verifying) == .skip)
    }

    @Test("Solo se confirma la salida con agentes trabajando o envíos en curso")
    func quitConfirmation() {
        #expect(QuitWorkInProgress(busyAgents: 0, runningSyncs: 0).message == nil)
        let one = QuitWorkInProgress(busyAgents: 1, runningSyncs: 0).message ?? ""
        #expect(one.hasPrefix("Un agente de Claude está trabajando."))
        let both = QuitWorkInProgress(busyAgents: 2, runningSyncs: 3).message ?? ""
        #expect(both.contains("2 agentes de Claude están trabajando y hay 3 envíos en curso"))
        #expect(both.contains("tmux"))
    }
}

@MainActor
@Suite("Ventanas del terminal")
struct TerminalWindowsModelTests {

    @Test("El sondeo se ralentiza sin cambios (3→6→12 s) y vuelve a 3 s ante uno")
    func adaptiveInterval() {
        var interval = TerminalWindowsModel.minInterval
        interval = TerminalWindowsModel.nextInterval(after: interval, changed: false)
        #expect(interval == .seconds(6))
        interval = TerminalWindowsModel.nextInterval(after: interval, changed: false)
        interval = TerminalWindowsModel.nextInterval(after: interval, changed: false)
        #expect(interval == .seconds(12))
        #expect(TerminalWindowsModel.nextInterval(after: interval, changed: true) == .seconds(3))
    }

    @Test("Las acciones de panel llegan al servidor")
    func paneActions() async {
        let mock = MockSSHService()
        let model = TerminalWindowsModel(service: mock, sessionName: "web")
        await model.splitPane(vertical: true)
        await model.selectPane(.left)
        await model.zoomPane()
        await model.killPane()
        #expect(mock.splitVerticalCalls == [true])
        #expect(mock.selectedPaneDirections == [.left])
        #expect(mock.zoomPaneCalls == 1)
        #expect(mock.killPaneCalls == 1)
        #expect(model.actionError == nil)
    }

    @Test("Sin conexión o con el Mac dormido, el sondeo no toca la red")
    func pollRespectsGate() async {
        let mock = MockSSHService()
        let model = TerminalWindowsModel(service: mock, sessionName: "web")
        var sleeps = 0
        await model.poll(while: { false }, sleep: { _ in
            sleeps += 1
            if sleeps == 3 { throw CancellationError() }
        })
        #expect(sleeps == 3)
        #expect(model.windows.isEmpty)
    }
}

@MainActor
@Suite("Reconexión automática del terminal")
struct TerminalReconnectSchedulerTests {

    private func scheduler(maxAttempts: Int = 3) -> TerminalReconnectScheduler {
        TerminalReconnectScheduler(
            policy: ReconnectPolicy(delays: [.milliseconds(1)], maxAttempts: maxAttempts),
            sleep: { _ in }
        )
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("Un fallo de red se reintenta solo hasta agotar los intentos")
    func retriesUntilExhausted() async {
        let reconnect = scheduler(maxAttempts: 2)
        var calls = 0
        for _ in 0..<3 {
            reconnect.didFail(nil, isAsleep: false) { calls += 1 }
            await settle()
        }
        #expect(calls == 2)
        #expect(reconnect.gaveUp == .attemptsExhausted)
        #expect(!reconnect.isReconnecting)
    }

    @Test("Una huella cambiada no se reintenta: hace falta el usuario")
    func hostKeyNeedsUser() async {
        let reconnect = scheduler()
        var calls = 0
        let mismatch = HostKeyMismatchError(endpoint: "h:22", storedFingerprint: "a", presentedFingerprint: "b")
        reconnect.didFail(mismatch, isAsleep: false) { calls += 1 }
        await settle()
        #expect(calls == 0)
        #expect(reconnect.gaveUp == .needsUserAction)
    }

    @Test("Dormido no se programa; al despertar se empieza de cero")
    func sleepAndWake() async {
        let reconnect = scheduler()
        var calls = 0
        reconnect.didFail(nil, isAsleep: true) { calls += 1 }
        await settle()
        #expect(calls == 0)
        reconnect.didWake(terminalFailed: true, lastError: nil) { calls += 1 }
        await settle()
        #expect(calls == 1)
        reconnect.didConnect()
        #expect(reconnect.attempt == 0)
    }

    @Test("«Reconectar» manual reinicia la cuenta y reconecta")
    func manualReconnect() async {
        let reconnect = scheduler(maxAttempts: 0)
        reconnect.didFail(nil, isAsleep: false) {}
        #expect(reconnect.gaveUp == .attemptsExhausted)
        var manual = 0
        reconnect.reconnectNow { manual += 1 }
        await settle()
        #expect(manual == 1)
        #expect(reconnect.gaveUp == nil)
    }
}
