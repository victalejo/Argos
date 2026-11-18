//
//  ReconnectPolicyTests.swift
//  ArgosTests
//
//  Reintentos automáticos del terminal: esperas con tope, tope de intentos y fallos que
//  exigen una acción del usuario (no se reintentan).
//

import Citadel
import Foundation
import Testing
@testable import Argos

@Suite("Política de reconexión del terminal")
struct ReconnectPolicyTests {
    private struct NetworkGlitch: Error {}
    private let policy = ReconnectPolicy.standard

    @Test("Las esperas siguen 1-2-4-8-15-30 s y repiten la última")
    func delays() {
        let seconds = (0..<8).map { policy.delay(forAttempt: $0) }
        #expect(seconds == [1, 2, 4, 8, 15, 30, 30, 30].map { Duration.seconds($0) })
        #expect(policy.delay(forAttempt: -3) == .seconds(1))
    }

    @Test("Un fallo de red se reintenta tras la espera que toca")
    func retriesNetworkErrors() {
        #expect(policy.decision(after: NetworkGlitch(), attempt: 0) == .retry(after: .seconds(1)))
        #expect(policy.decision(after: NetworkGlitch(), attempt: 3) == .retry(after: .seconds(8)))
    }

    @Test("Tras el tope de intentos se deja en manos del usuario")
    func stopsAfterMaxAttempts() {
        #expect(policy.decision(after: NetworkGlitch(), attempt: 8) == .giveUp(.attemptsExhausted))
    }

    @Test("Huella cambiada o registro ilegible: no se reintenta")
    func hostKeyNeedsUser() {
        let mismatch = HostKeyMismatchError(endpoint: "h:22", storedFingerprint: "a", presentedFingerprint: "b")
        #expect(policy.decision(after: mismatch, attempt: 0) == .giveUp(.needsUserAction))
        #expect(!ReconnectPolicy.isRetryable(HostKeyStoreUnreadableError(endpoint: "h:22")))
    }

    @Test("Credenciales y claves: no se reintenta")
    func credentialsNeedUser() {
        #expect(!ReconnectPolicy.isRetryable(SSHService.SSHServiceError.credentialUnavailable))
        #expect(!ReconnectPolicy.isRetryable(SSHService.SSHServiceError.keyParseFailed(underlying: NetworkGlitch())))
        #expect(!ReconnectPolicy.isRetryable(SSHClientError.allAuthenticationOptionsFailed))
        #expect(!ReconnectPolicy.isRetryable(ImportedKeyStore.ImportError.unreadable))
    }

    @Test("La sesión ya no existe (tmux attach falla): no se reintenta")
    func missingSessionNeedsUser() {
        #expect(!ReconnectPolicy.isRetryable(SSHService.SSHServiceError.commandFailed(exitCode: 1, message: "no session")))
    }

    @Test("No poder abrir un canal sí se reintenta")
    func channelCreationRetries() {
        #expect(ReconnectPolicy.isRetryable(SSHClientError.channelCreationFailed))
    }
}
