//
//  ConnectionHealthTests.swift
//  ArgosTests
//
//  Salud de la conexión: credenciales rechazadas o host key cambiada bloquean los
//  reintentos hasta que el usuario actúe; un fallo de red hace esperar 1→60 s a los
//  sondeos de fondo, nunca al usuario; un éxito lo reinicia.
//

import Foundation
import Testing
@preconcurrency import Citadel
@testable import Argos

@Suite("Salud de la conexión SSH")
struct ConnectionHealthTests {

    private let t0 = ContinuousClock.now

    @Test("La espera crece 1, 2, 4… y se queda en 60 s")
    func backoffGrows() {
        let waits = (1...9).map { ConnectionHealth.backoff(afterFailures: $0) }
        #expect(waits.map { $0.components.seconds } == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(ConnectionHealth.backoff(afterFailures: 0) == .seconds(1))
        #expect(ConnectionHealth.backoff(afterFailures: 500) == .seconds(60))
    }

    @Test("Sana: todos pueden conectar")
    func healthyAllowsEveryone() {
        let health = ConnectionHealth()
        #expect(health.admission(for: .background, at: t0) == .allowed)
        #expect(health.admission(for: .user, at: t0) == .allowed)
    }

    @Test("Fallo de red: el fondo espera, el usuario no")
    func networkFailureDefersBackground() {
        let health = ConnectionHealth().recordingFailure(.network, message: "caído", at: t0)
        #expect(health.admission(for: .user, at: t0) == .allowed)
        #expect(health.admission(for: .background, at: t0) == .deferred(remaining: .seconds(1)))
        #expect(health.admission(for: .background, at: t0 + .seconds(1)) == .allowed)
        #expect(health.lastFailureMessage == "caído")
    }

    @Test("Fallos de red seguidos alargan la espera; un éxito la reinicia")
    func consecutiveFailuresAndSuccess() {
        var health = ConnectionHealth()
        for _ in 0..<3 { health = health.recordingFailure(.network, message: "x", at: t0) }
        #expect(health.status == .backingOff(failures: 3, retryAt: t0 + .seconds(4)))
        #expect(health.admission(for: .background, at: t0 + .seconds(3)) == .deferred(remaining: .seconds(1)))
        let recovered = health.recordingSuccess()
        #expect(recovered == ConnectionHealth())
        #expect(recovered.admission(for: .background, at: t0) == .allowed)
    }

    @Test("Credenciales rechazadas o host key: bloqueo para todos", arguments: [SSHFailureKind.authentication, .hostKey])
    func blockingFailures(kind: SSHFailureKind) {
        let health = ConnectionHealth().recordingFailure(kind, message: "no", at: t0)
        #expect(health.isBlocked)
        #expect(health.admission(for: .user, at: t0 + .seconds(3600)) == .blocked(kind))
        #expect(health.admission(for: .background, at: t0 + .seconds(3600)) == .blocked(kind))
    }

    @Test("Bloqueado + fallo de red: sigue bloqueado")
    func blockedIgnoresNetworkFailure() {
        let blocked = ConnectionHealth().recordingFailure(.authentication, message: "no", at: t0)
        let after = blocked.recordingFailure(.network, message: "red", at: t0)
        #expect(after == blocked)
        #expect(after.admission(for: .user, at: t0) == .blocked(.authentication))
    }

    @Test("Quien se une como usuario a un intento de fondo en espera reintenta por su cuenta")
    func joinerRetry() {
        let deferred = SSHConnectionError.backingOff(retryIn: .seconds(4), lastFailure: nil)
        #expect(ConnectionHealth.joinerShouldRetry(after: deferred, priority: .user))
        #expect(!ConnectionHealth.joinerShouldRetry(after: deferred, priority: .background))
        #expect(!ConnectionHealth.joinerShouldRetry(after: URLError(.timedOut), priority: .user))
        #expect(!ConnectionHealth.joinerShouldRetry(after: SSHClientError.allAuthenticationOptionsFailed, priority: .user))
    }

    @Test("«Conexión perdida» no promete una reconexión que no todos hacen")
    func connectionLostWording() {
        #expect(!(SSHConnectionError.connectionLost.errorDescription ?? "").contains("Reconectando"))
    }

    // MARK: - Clasificación

    @Test("Clasifica los fallos de autenticación")
    func classifiesAuthentication() {
        #expect(SSHFailureKind.classify(SSHClientError.allAuthenticationOptionsFailed) == .authentication)
        #expect(SSHFailureKind.classify(SSHClientError.unsupportedPasswordAuthentication) == .authentication)
        #expect(SSHFailureKind.classify(CitadelError.unauthorized) == .authentication)
        #expect(SSHFailureKind.classify(SSHService.SSHServiceError.credentialUnavailable) == .authentication)
    }

    @Test("Clasifica host key, red y cancelación")
    func classifiesOthers() {
        let mismatch = HostKeyMismatchError(endpoint: "h:22", storedFingerprint: "a", presentedFingerprint: "b")
        #expect(SSHFailureKind.classify(mismatch) == .hostKey)
        #expect(SSHFailureKind.classify(HostKeyStoreUnreadableError(endpoint: "h:22")) == .hostKey)
        #expect(SSHFailureKind.classify(SSHClientError.channelCreationFailed) == .network)
        #expect(SSHFailureKind.classify(URLError(.timedOut)) == .network)
        #expect(SSHFailureKind.classify(CancellationError()) == nil)
        #expect(SSHFailureKind.blocking(URLError(.timedOut)) == nil)
        #expect(SSHFailureKind.blocking(mismatch) == .hostKey)
    }
}

// MARK: - Aplicada en SSHService (sin red)

@Suite("Salud de la conexión en SSHService")
struct SSHServiceHealthTests {

    private func makeService(auth: AuthMethod = .key, password: String? = nil) -> SSHService {
        let server = Server(name: "prueba", host: "127.0.0.1", username: "nadie", authMethod: auth)
        return SSHService(configuration: SSHService.Configuration(server: server, password: password))
    }

    @Test("Sin contraseña: no toca la red y queda bloqueado hasta que el usuario actúe")
    func missingPasswordBlocks() async {
        let service = makeService(auth: .password, password: nil)
        await #expect(throws: SSHService.SSHServiceError.self) { _ = try await service.openClient() }
        #expect(await service.connectionHealth.isBlocked)
        // Ni siquiera una acción del usuario reintenta sin reiniciar la salud.
        await #expect(throws: SSHService.SSHServiceError.self) { try await service.admitConnectionAttempt() }
        await service.resetConnectionHealth()
        #expect(await service.connectionHealth == ConnectionHealth())
    }

    @Test("Tras un fallo de red el fondo espera y el usuario no")
    func networkFailureBackoff() async throws {
        let service = makeService()
        let now = ContinuousClock.now
        await service.recordConnectionFailure(URLError(.cannotConnectToHost), now: now)
        try await service.admitConnectionAttempt(now: now)
        await #expect(throws: SSHConnectionError.self) {
            try await ConnectionPriority.background { try await service.admitConnectionAttempt(now: now) }
        }
        try await ConnectionPriority.background {
            try await service.admitConnectionAttempt(now: now + .seconds(2))
        }
    }

    @Test("Host key cambiada: se relanza el error original (la UI ofrece «Olvidar host key»)")
    func hostKeyRethrowsOriginal() async {
        // Endpoint propio de este test: la huella vive en el registro real de la app.
        let host = "argos-test-\(UUID().uuidString).invalid"
        let port = 2222
        TOFUHostKeyValidator.trustIfUnknown(fingerprint: "SHA256:guardada", host: host, port: port)
        defer { TOFUHostKeyValidator.forget(host: host, port: port) }
        let service = SSHService(configuration: .init(server: Server(name: "p", host: host, port: port, username: "u")))
        let mismatch = HostKeyMismatchError(
            endpoint: "\(host):\(port)", storedFingerprint: "SHA256:guardada", presentedFingerprint: "SHA256:otra"
        )
        await service.recordConnectionFailure(mismatch)
        await #expect(throws: HostKeyMismatchError.self) { try await service.admitConnectionAttempt() }

        // «Olvidar host key» (aunque se pulse en otro sitio) levanta el bloqueo.
        TOFUHostKeyValidator.forget(host: host, port: port)
        await #expect(throws: Never.self) { try await service.admitConnectionAttempt() }
        #expect(await service.connectionHealth == ConnectionHealth())
    }

    @Test("Un fallo de red no degrada un bloqueo por credenciales")
    func networkFailureKeepsBlock() async {
        let service = makeService(auth: .password, password: nil)
        _ = try? await service.openClient()
        await service.recordConnectionFailure(URLError(.timedOut))
        #expect(await service.connectionHealth.isBlocked)
        await #expect(throws: SSHService.SSHServiceError.self) { try await service.admitConnectionAttempt() }
    }

    @Test("La cancelación no cuenta como fallo")
    func cancellationIsIgnored() async {
        let service = makeService()
        await service.recordConnectionFailure(CancellationError())
        #expect(await service.connectionHealth == ConnectionHealth())
    }

    @Test("La prioridad de fondo viaja con la tarea")
    func priorityTravels() async {
        #expect(ConnectionPriority.current == .user)
        let inside = await ConnectionPriority.background { ConnectionPriority.current }
        #expect(inside == .background)
        let inherited = await ConnectionPriority.background {
            await Task { ConnectionPriority.current }.value
        }
        #expect(inherited == .background)
    }
}
