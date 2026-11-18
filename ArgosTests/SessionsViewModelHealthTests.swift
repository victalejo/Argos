//
//  SessionsViewModelHealthTests.swift
//  ArgosTests
//
//  Los sondeos del view model van como trabajo de fondo, y un fallo que no se arregla
//  solo (contraseña rechazada, host key cambiada) se muestra en vez de seguir «cargado».
//  Las acciones explícitas (`load`, `refresh`) levantan el bloqueo de la conexión.
//

import Foundation
import Testing
@preconcurrency import Citadel
@testable import Argos

@MainActor
@Suite("SessionsViewModel: salud de la conexión")
struct SessionsViewModelHealthTests {

    private func loadedViewModel() async -> (SessionsViewModel, MockSSHService) {
        let mock = MockSSHService()
        mock.sessions = [TmuxSession(name: "main", windowCount: 1, isAttached: false,
                                     createdAt: Date(timeIntervalSince1970: 0))]
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        return (vm, mock)
    }

    @Test("load y refresh son acciones del usuario: reinician la salud de la conexión")
    func explicitActionsResetHealth() async {
        let (vm, mock) = await loadedViewModel()
        #expect(mock.healthResets == 1)
        await vm.refresh()
        #expect(mock.healthResets == 2)
    }

    @Test("El sondeo de sesiones va como trabajo de fondo")
    func quietRefreshIsBackground() async {
        let (vm, mock) = await loadedViewModel()
        var seen: ConnectionPriority?
        mock.onListSessions = { seen = ConnectionPriority.current }
        await vm.refreshSessionsQuietly()
        #expect(seen == .background)
        // Lo explícito, no.
        await vm.refresh()
        #expect(seen == .user)
    }

    @Test("Contraseña rechazada en un sondeo: la lista pasa a error")
    func authenticationFailureShowsError() async {
        let (vm, mock) = await loadedViewModel()
        mock.listError = SSHClientError.allAuthenticationOptionsFailed
        await vm.refreshSessionsQuietly()
        guard case .failed(let message) = vm.state else {
            Issue.record("Esperaba .failed, fue \(vm.state)")
            return
        }
        #expect(message == SSHErrorMessage.authenticationRejected)
    }

    @Test("Host key cambiada en un sondeo: se ofrece la acción dedicada")
    func hostKeyFailureShowsAction() async {
        let (vm, mock) = await loadedViewModel()
        mock.listError = HostKeyMismatchError(endpoint: "h:22", storedFingerprint: "a", presentedFingerprint: "b")
        await vm.refreshSessionsQuietly()
        guard case .hostKeyChanged = vm.state else {
            Issue.record("Esperaba .hostKeyChanged, fue \(vm.state)")
            return
        }
    }

    @Test("Un fallo de red en un sondeo conserva lo último")
    func networkFailureKeepsList() async {
        let (vm, mock) = await loadedViewModel()
        mock.listError = SSHConnectionError.backingOff(retryIn: .seconds(4), lastFailure: "caído")
        await vm.refreshSessionsQuietly()
        #expect(vm.sessions.map(\.name) == ["main"])
        mock.listError = URLError(.timedOut)
        await vm.refreshSessionsQuietly()
        #expect(vm.sessions.map(\.name) == ["main"])
    }

    @Test("Un fallo bloqueante no pisa un arranque en curso")
    func blockingFailureOnlyWhenLoaded() {
        let vm = SessionsViewModel(service: MockSSHService())
        vm.noteBackgroundFailure(SSHClientError.allAuthenticationOptionsFailed, during: "prueba")
        guard case .idle = vm.state else {
            Issue.record("Esperaba .idle, fue \(vm.state)")
            return
        }
    }
}
