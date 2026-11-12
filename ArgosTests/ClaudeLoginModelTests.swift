//
//  ClaudeLoginModelTests.swift
//  ArgosTests
//
//  Login guiado de Claude sin terminal (`ClaudeLoginModel`, iPhone/iPad): fases, envío
//  del código al PTY y comprobación de la sesión, contra el mock.
//

import Foundation
import Testing
@testable import Argos

@MainActor
@Suite("Login de Claude: flujo guiado")
struct ClaudeLoginModelTests {

    private static let loggedOut = ClaudeAuthStatus(loggedIn: false, subscriptionType: nil, email: nil)
    private static let loggedIn = ClaudeAuthStatus(loggedIn: true, subscriptionType: "max", email: "a@b.c")

    private func makeService(open: Bool = true) -> MockSSHService {
        let service = MockSSHService()
        service.authStatus = Self.loggedOut
        service.commandOutput = [ClaudeLoginOutputTests.realOutput]
        service.commandStaysOpen = open
        return service
    }

    private func makeModel(_ service: MockSSHService, attempts: Int = 200) -> ClaudeLoginModel {
        ClaudeLoginModel(service: service, verifyInterval: .milliseconds(5), verifyAttempts: attempts)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("La condición no se cumplió a tiempo")
    }

    @Test("Lanza el login con la ruta del binario y ofrece el enlace")
    func offersLink() async throws {
        let service = makeService()
        let model = makeModel(service)
        model.start()
        try await waitUntil { model.phase == .authorize }

        #expect(service.attachedCommands == ["'/usr/bin/claude' auth login --claudeai"])
        #expect(model.authorizationURL?.absoluteString == ClaudeLoginOutputTests.url)
        #expect(model.canSubmitCode)
        #expect(model.transcript.contains("Paste code here"))
        model.stop()
    }

    @Test("El código se teclea limpio y la sesión se confirma")
    func submitsCodeAndVerifies() async throws {
        let service = makeService()
        service.onCommandInput = { _ in service.authStatus = Self.loggedIn }
        let model = makeModel(service)
        model.start()
        try await waitUntil { model.canSubmitCode }

        model.submit(code: "  abc#123\nrm -rf\n ")
        try await waitUntil { model.phase == .success("Conectado · plan Max · a@b.c") }

        #expect(service.commandInput == ["abc#123rm -rf\r"])
        #expect(!model.isRunning)
    }

    @Test("Un código vacío no se envía")
    func ignoresEmptyCode() async throws {
        let service = makeService()
        let model = makeModel(service)
        model.start()
        try await waitUntil { model.canSubmitCode }

        model.submit(code: " \n ")
        #expect(model.phase == .authorize)
        #expect(service.commandInput.isEmpty)
        model.stop()
    }

    @Test("Si no se confirma a tiempo, falla y deja reintentar el código")
    func verificationTimesOut() async throws {
        let service = makeService()
        let model = makeModel(service, attempts: 2)
        model.start()
        try await waitUntil { model.canSubmitCode }

        model.submit(code: "malo")
        try await waitUntil { if case .failed = model.phase { return true } else { return false } }
        #expect(model.canSubmitCode)
        model.stop()
    }

    @Test("El comando se cierra sin sesión: falla sin esperar")
    func commandEndsWithoutSession() async throws {
        let service = makeService(open: false)
        let model = makeModel(service)
        model.start()
        try await waitUntil { model.phase == .failed("El inicio de sesión se cerró sin completarse.") }
        #expect(!model.canSubmitCode)
    }

    @Test("El comando se cierra con la sesión ya iniciada: éxito")
    func commandEndsLoggedIn() async throws {
        let service = makeService(open: false)
        service.authStatus = Self.loggedIn
        let model = makeModel(service)
        model.start()
        try await waitUntil { if case .success = model.phase { return true } else { return false } }
    }

    @Test("Sin Claude instalado lo dice y no abre el PTY")
    func claudeMissing() async throws {
        let service = makeService()
        service.claudePath = nil
        let model = makeModel(service)
        model.start()
        try await waitUntil { model.phase == .failed("Claude Code no está instalado en este servidor.") }
        #expect(service.attachedCommands.isEmpty)
    }

    @Test("Un fallo de conexión muestra su mensaje")
    func connectionFailure() async throws {
        let service = makeService()
        service.commandError = SSHService.SSHServiceError.commandFailed(exitCode: 1, message: "sin red")
        let model = makeModel(service)
        model.start()
        try await waitUntil { if case .failed = model.phase { return true } else { return false } }
        #expect(model.phase == .failed(SSHService.SSHServiceError.commandFailed(exitCode: 1, message: "sin red").userMessage))
    }

    @Test("Empezar de nuevo descarta el enlace anterior y relanza")
    func restart() async throws {
        let service = makeService()
        let model = makeModel(service)
        model.start()
        try await waitUntil { model.phase == .authorize }

        model.start()
        #expect(model.phase == .starting)
        #expect(model.authorizationURL == nil)
        try await waitUntil { model.phase == .authorize }
        #expect(service.attachedCommands.count == 2)
        model.stop()
    }
}
