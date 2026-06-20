//
//  SessionsViewModelTests.swift
//  ArgosTests
//
//  Cubre la máquina de estados de carga (bootstrap de tmux) y la gestión de sesiones
//  del ViewModel, usando `MockSSHService` (sin servidor SSH real).
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("SessionsViewModel")
struct SessionsViewModelTests {

    private func session(_ name: String) -> TmuxSession {
        TmuxSession(name: name, windowCount: 1, isAttached: false,
                    createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("load: tmux presente y configurado → estado cargado con las sesiones")
    func loadsSessionsHappyPath() async {
        let mock = MockSSHService()
        mock.sessions = [session("main"), session("deploy")]
        let vm = SessionsViewModel(service: mock)

        await vm.load()

        #expect(vm.sessions.count == 2)
        if case .loaded(let s) = vm.state {
            #expect(s.map(\.name) == ["main", "deploy"])
        } else {
            Issue.record("Esperaba .loaded, fue \(vm.state)")
        }
        #expect(mock.clipboardForwardingCalled)
    }

    @Test("load: tmux ausente y sin sudo → estado tmuxMissing (sin instalar)")
    func tmuxMissingWithoutSudo() async {
        let mock = MockSSHService()
        mock.tmuxInstalled = false
        mock.hasSudo = false
        let vm = SessionsViewModel(service: mock)

        await vm.load()

        if case .tmuxMissing = vm.state {} else {
            Issue.record("Esperaba .tmuxMissing, fue \(vm.state)")
        }
        #expect(mock.installCalled == false)
    }

    @Test("load: tmux ausente con sudo → instala y termina cargado")
    func installsTmuxWhenSudoAvailable() async {
        let mock = MockSSHService()
        mock.tmuxInstalled = false
        mock.hasSudo = true
        mock.configExists = true
        let vm = SessionsViewModel(service: mock)

        await vm.load()

        #expect(mock.installCalled)
        if case .loaded = vm.state {} else {
            Issue.record("Esperaba .loaded tras instalar, fue \(vm.state)")
        }
    }

    @Test("load: sin ~/.tmux.conf → lo escribe")
    func writesConfigWhenMissing() async {
        let mock = MockSSHService()
        mock.configExists = false
        let vm = SessionsViewModel(service: mock)

        await vm.load()

        #expect(mock.writeConfigCalled)
    }

    @Test("load: host key cambiada → estado hostKeyChanged (no failed genérico)")
    func hostKeyMismatchSurfacesDedicatedState() async {
        let mock = MockSSHService()
        mock.listError = HostKeyMismatchError(
            endpoint: "h:22",
            storedFingerprint: "SHA256:vieja",
            presentedFingerprint: "SHA256:nueva"
        )
        let vm = SessionsViewModel(service: mock)

        await vm.load()

        if case .hostKeyChanged = vm.state {} else {
            Issue.record("Esperaba .hostKeyChanged, fue \(vm.state)")
        }
    }

    @Test("load: error genérico de conexión → estado failed")
    func genericErrorSurfacesFailed() async {
        struct Boom: Error {}
        let mock = MockSSHService()
        mock.listError = Boom()
        let vm = SessionsViewModel(service: mock)

        await vm.load()

        if case .failed = vm.state {} else {
            Issue.record("Esperaba .failed, fue \(vm.state)")
        }
    }

    @Test("kill: si el servicio falla, se expone operationError")
    func killSurfacesOperationError() async {
        struct Boom: Error {}
        let mock = MockSSHService()
        mock.sessions = [session("main")]
        mock.killError = Boom()
        let vm = SessionsViewModel(service: mock)
        await vm.load()

        await vm.kill(session("main"))

        #expect(vm.operationError != nil)
    }

    @Test("kill: éxito → la sesión desaparece y no hay error")
    func killRemovesSession() async {
        let mock = MockSSHService()
        mock.sessions = [session("main"), session("deploy")]
        let vm = SessionsViewModel(service: mock)
        await vm.load()

        await vm.kill(session("main"))

        #expect(mock.killedNames == ["main"])
        #expect(vm.sessions.map(\.name) == ["deploy"])
        #expect(vm.operationError == nil)
    }

    @Test("create: nombre válido → llama al servicio y refresca")
    func createAddsSession() async throws {
        let mock = MockSSHService()
        let vm = SessionsViewModel(service: mock)
        await vm.load()

        try await vm.createSession(named: "nueva")

        #expect(mock.createdNames == ["nueva"])
        #expect(vm.sessions.contains { $0.name == "nueva" })
    }

    @Test("create: nombre inválido → lanza y no llama al servicio")
    func createRejectsInvalidName() async {
        let mock = MockSSHService()
        let vm = SessionsViewModel(service: mock)
        await vm.load()

        await #expect(throws: (any Error).self) {
            try await vm.createSession(named: "tiene:dos.puntos")
        }
        #expect(mock.createdNames.isEmpty)
    }
}
