//
//  ClaudeLoginModel.swift
//  Argos
//
//  Login guiado de Claude en el SERVIDOR sin emulador de terminal: corre
//  `claude auth login --claudeai` en un PTY remoto, lee su salida con
//  `ClaudeLoginOutput` y la convierte en pasos (abrir el enlace → pegar el código →
//  comprobar con `claude auth status`). Lo usa el iPhone/iPad; el Mac tiene su hoja con
//  terminal a la vista (`ClaudeSetupSheet`).
//
//  Ni la salida ni el código se registran en el log.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeLoginModel {

    enum Phase: Equatable {
        /// Abriendo el PTY; aún no hay enlace.
        case starting
        /// Hay enlace: falta que el usuario autorice y pegue el código.
        case authorize
        /// Código enviado: comprobando la sesión.
        case verifying
        case success(String)
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    /// Solo de dominios de Anthropic (`ClaudeLoginOutput`): la salida viene del servidor.
    private(set) var authorizationURL: URL?
    private(set) var isAwaitingCode = false
    /// El comando sigue vivo en el servidor (se le puede teclear el código).
    private(set) var isRunning = false
    /// Salida visible del comando, sin secuencias de escape («Detalles técnicos»).
    private(set) var transcript = ""

    /// Se puede enviar el código: el CLI lo pide, sigue vivo y no se está comprobando ya.
    var canSubmitCode: Bool {
        guard isRunning, isAwaitingCode else { return false }
        switch phase {
        case .authorize, .failed: return true
        case .starting, .verifying, .success: return false
        }
    }

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored private let verifyInterval: Duration
    @ObservationIgnored private let verifyAttempts: Int
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private var input: AsyncStream<TerminalControlEvent>.Continuation?
    /// Cambia en cada `start()`/`stop()`: un intento anterior que termina tarde no toca
    /// el estado del actual.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var raw = ""

    /// PTY muy ancho: el CLI parte las líneas largas según las columnas y el enlace
    /// (unos 450 caracteres con `scope`, `code_challenge` y `state`) debe llegar entero.
    static let columns = 2000
    static let rows = 50
    /// Tope de salida analizada (se conserva lo último): el flujo entero ocupa mucho menos.
    private static let maxOutputCharacters = 20_000

    init(service: any SSHServicing, verifyInterval: Duration = .seconds(2), verifyAttempts: Int = 30) {
        self.service = service
        self.verifyInterval = verifyInterval
        self.verifyAttempts = verifyAttempts
    }

    static func command(claudePath: String) -> String {
        "\(ShellQuoting.singleQuoted(claudePath)) auth login --claudeai"
    }

    /// Texto de «sesión iniciada»: plan y correo si el CLI los informa.
    static func connectedMessage(_ status: ClaudeAuthStatus) -> String {
        var parts = ["Conectado"]
        if let plan = status.subscriptionType, !plan.isEmpty { parts.append("plan \(plan.capitalized)") }
        if let email = status.email, !email.isEmpty { parts.append(email) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Ciclo de vida

    /// Lanza el comando desde cero (también «Empezar de nuevo»: el enlace anterior deja de valer).
    func start() {
        stop()
        let current = generation
        phase = .starting
        authorizationURL = nil
        isAwaitingCode = false
        transcript = ""
        raw = ""
        runTask = Task { [weak self] in await self?.run(generation: current) }
    }

    /// Corta el comando (cerrar la hoja). No deshace una sesión ya iniciada.
    func stop() {
        generation += 1
        verifyTask?.cancel()
        verifyTask = nil
        closeCommand()
    }

    private func closeCommand() {
        input?.finish()
        input = nil
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    private func run(generation current: Int) async {
        var failure: Error?
        do {
            guard let claudePath = try await service.locateClaude() else {
                if generation == current { phase = .failed("Claude Code no está instalado en este servidor.") }
                return
            }
            guard generation == current, !Task.isCancelled else { return }

            let (control, controlInput) = AsyncStream<TerminalControlEvent>.makeStream()
            let (output, outputSink) = AsyncStream<[UInt8]>.makeStream()
            input = controlInput
            isRunning = true
            let reader = Task { @MainActor [weak self] in
                for await bytes in output { self?.consume(bytes, generation: current) }
            }
            do {
                try await service.attachCommand(
                    command: Self.command(claudePath: claudePath),
                    initialCols: Self.columns,
                    initialRows: Self.rows,
                    control: control,
                    output: outputSink
                )
            } catch {
                failure = error
            }
            outputSink.finish()
            await reader.value
        } catch {
            failure = error
        }
        await commandEnded(generation: current, error: failure)
    }

    private func consume(_ bytes: [UInt8], generation current: Int) {
        guard generation == current else { return }
        raw += String(decoding: bytes, as: UTF8.self)
        if raw.count > Self.maxOutputCharacters { raw = String(raw.suffix(Self.maxOutputCharacters)) }
        transcript = ClaudeLoginOutput.stripEscapes(raw)
        let parsed = ClaudeLoginOutput.parse(raw)
        if let url = parsed.authorizationURL { authorizationURL = url }
        if parsed.isAwaitingCode { isAwaitingCode = true }
        if authorizationURL != nil, phase == .starting { phase = .authorize }
    }

    /// El comando terminó (bien, mal o porque se cayó la conexión): una última
    /// comprobación decide. Con el código ya enviado no se espera al sondeo: si el CLI
    /// salió sin dejar sesión, el código no valía.
    private func commandEnded(generation current: Int, error: Error?) async {
        guard generation == current else { return }
        isRunning = false
        input = nil
        if case .success = phase { return }
        let wasVerifying = phase == .verifying
        verifyTask?.cancel()
        verifyTask = nil

        let status = try? await service.claudeAuthStatus()
        guard generation == current else { return }
        if let status, status.loggedIn {
            succeed(status)
        } else if wasVerifying {
            phase = .failed("No se pudo confirmar la sesión. Revisa el código y vuelve a intentarlo.")
        } else if let error, !(error is CancellationError) {
            phase = .failed(error.userMessage)
        } else {
            phase = .failed("El inicio de sesión se cerró sin completarse.")
        }
    }

    // MARK: - Código

    /// Teclea en el PTY el código que da la página y empieza a comprobar la sesión.
    /// Sin caracteres de control: un salto de línea pegado no debe teclear nada más.
    func submit(code: String) {
        let cleaned = String(String.UnicodeScalarView(
            code.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        )).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, canSubmitCode, let input else { return }
        input.yield(.input(Array((cleaned + "\r").utf8)))
        phase = .verifying
        verify()
    }

    private func verify() {
        verifyTask?.cancel()
        let current = generation
        let interval = verifyInterval
        let attempts = verifyAttempts
        verifyTask = Task { [weak self] in
            for _ in 0..<attempts {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.generation == current else { return }
                let status = try? await self.service.claudeAuthStatus()
                guard !Task.isCancelled, self.generation == current else { return }
                if let status, status.loggedIn {
                    self.succeed(status)
                    return
                }
            }
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.phase = .failed("No se pudo confirmar la sesión. Revisa el código y vuelve a intentarlo.")
        }
    }

    private func succeed(_ status: ClaudeAuthStatus) {
        phase = .success(Self.connectedMessage(status))
        verifyTask = nil
        // El CLI sale solo al terminar; si no lo hace, no se deja el PTY abierto.
        closeCommand()
    }
}
