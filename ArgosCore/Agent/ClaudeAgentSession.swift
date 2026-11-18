//
//  ClaudeAgentSession.swift
//  Argos
//
//  Controlador en vivo de una sesión de agente Claude Code remota. Análogo a
//  `LiveTerminalController` pero para el canal exec + protocolo stream-json:
//   - stdout del proceso -> NDJSON -> eventos -> `AgentReducer` -> `state` (observable)
//   - acciones del usuario (prompt / decisión de permiso / interrumpir) -> stdin
//
//  Vive en el `MainActor`. El stream de stdin es `let` (Sendable) para encolar sin
//  saltos de actor. El stream de stdout NO se acota (perder una línea NDJSON
//  rompería el protocolo, p. ej. una solicitud de permiso).
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeAgentSession {

    /// Estado observable de la conversación (transcript, status, permiso pendiente).
    private(set) var state: AgentConversationState

    /// Se pidió interrumpir el turno y aún no llegó su `result`.
    private(set) var isInterrupting = false

    /// Directorio de trabajo remoto donde corre el agente (informativo para la UI).
    let workingDirectory: String
    /// Id de sesión de Claude (`--session-id`/`--resume`): permite reanudarla y
    /// reconocer su proceso en el servidor.
    let sessionID: String

    private let service: any SSHServicing
    private let command: String

    private var task: Task<Void, Never>?
    private var isStopping = false

    // Stream de stdin (prompts y control_response). `let` Sendable: se puede encolar
    // desde cualquier método sin cruzar de actor.
    private let stdinStream: AsyncStream<[UInt8]>
    private let stdinContinuation: AsyncStream<[UInt8]>.Continuation

    /// `oauthToken`: se envía como primera línea de stdin (ver `ClaudeAgentCommand.build`).
    /// `initialState`: la conversación previa al reanudar (`--resume` no la repite).
    init(
        service: any SSHServicing,
        command: String,
        workingDirectory: String,
        oauthToken: String?,
        sessionID: String = "",
        initialState: AgentConversationState = AgentConversationState()
    ) {
        self.service = service
        self.command = command
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID.lowercased()
        var state = initialState
        state.pendingPermission = nil
        state.status = .idle
        self.state = state
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        self.stdinStream = stream
        self.stdinContinuation = continuation
        continuation.yield(ClaudeAgentCommand.tokenLine(oauthToken))
        start()
    }

    /// El proceso remoto sigue en marcha (no terminó ni falló).
    var isRunning: Bool {
        switch state.status {
        case .finished, .failed: return false
        case .connecting, .idle, .working: return true
        }
    }

    /// Trabajando o esperando un permiso: cerrarla perdería algo en curso.
    var isBusy: Bool {
        state.pendingPermission != nil || state.status == .working
    }

    /// Tiene algo que reanudar (al menos un mensaje del usuario).
    var hasConversation: Bool {
        state.items.contains { if case .userText = $0.kind { return true } else { return false } }
    }

    // MARK: - Acciones del usuario

    /// Envía un prompt del usuario al agente.
    func sendUserText(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AgentReducer.userSent(text: text, to: &state)
        writeLine(AgentProtocol.encodeUserMessage(text: text))
    }

    /// Responde a la solicitud de permiso pendiente (Permitir / Denegar).
    func respond(to request: AgentPermissionRequest, decision: AgentPermissionDecision) {
        writeLine(AgentProtocol.encodePermissionResponse(requestID: request.id, decision: decision))
        if state.pendingPermission?.id == request.id {
            state.pendingPermission = nil
        }
    }

    /// Atajo: permite la herramienta con su input original.
    func allowPendingPermission() {
        guard let request = state.pendingPermission else { return }
        respond(to: request, decision: .allow(updatedInput: request.input))
    }

    /// Atajo: deniega la herramienta pendiente.
    func denyPendingPermission() {
        guard let request = state.pendingPermission else { return }
        respond(to: request, decision: .deny(message: "El usuario denegó esta acción."))
    }

    /// «Detener»: corta el turno en curso con la petición de control `interrupt`. La
    /// conversación sigue abierta (el CLI cierra el turno con un `result`).
    func interrupt() {
        guard isRunning, state.status == .working || state.pendingPermission != nil else { return }
        isInterrupting = true
        writeLine(AgentProtocol.encodeInterrupt(requestID: "argos-interrupt-\(UUID().uuidString.lowercased())"))
        // Un permiso pendiente queda sin sentido: el CLI lo cancela al interrumpir.
        state.pendingPermission = nil
    }

    private func writeLine(_ line: String) {
        guard !line.isEmpty else { return }
        stdinContinuation.yield(Array((line + "\n").utf8))
    }

    // MARK: - Ciclo de vida

    private func start() {
        guard task == nil else { return }

        // SIN acotar: cada línea NDJSON debe llegar (no se pueden descartar control_request).
        let (outputStream, outputContinuation) = AsyncStream<[UInt8]>.makeStream()
        let service = self.service
        let command = self.command
        let stdin = self.stdinStream

        task = Task { [weak self] in
            // Parser (MainActor): NDJSON -> eventos -> reducer.
            let parser = Task { @MainActor [weak self] in
                var buffer = NDJSONLineBuffer()
                for await chunk in outputStream {
                    for line in buffer.append(chunk) {
                        self?.handle(line: line)
                    }
                }
            }

            do {
                try await service.runAgentExec(
                    command: command,
                    stdin: stdin,
                    output: outputContinuation
                )
                self?.finish(error: nil)
            } catch is CancellationError {
                // Parada normal.
            } catch {
                self?.finish(error: error)
            }

            parser.cancel()
        }
    }

    private func handle(line: String) {
        if let pid = ClaudeAgentCommand.announcedPID(in: line) {
            remotePID = pid
            return
        }
        guard let event = AgentProtocol.decode(line: line) else { return }
        if case .result = event { isInterrupting = false }
        AgentReducer.apply(event, to: &state)
    }

    /// PID del `claude` remoto (lo anuncia el comando al arrancar).
    private(set) var remotePID: Int32?

    /// Detiene el agente: finaliza stdin (EOF -> el proceso remoto sale), cancela y,
    /// por si el proceso no saliera solo (p. ej. bloqueado en un hook), lo mata por PID.
    /// Así no quedan `claude` huérfanos consumiendo memoria en el servidor.
    func stop() {
        guard let pid = beginStop() else { return }
        let service = self.service
        Task.detached { await service.killAgentProcess(pid: pid) }
    }

    /// Como `stop()`, pero ESPERA a que el proceso remoto se mate (p. ej. al salir de la
    /// app, que no puede dejar tareas sueltas).
    func stopAndWait() async {
        guard let pid = beginStop() else { return }
        await service.killAgentProcess(pid: pid)
    }

    private func beginStop() -> Int32? {
        isStopping = true
        isInterrupting = false
        stdinContinuation.finish()
        task?.cancel()
        task = nil
        if isRunning { AgentReducer.finished(error: nil, to: &state) }
        defer { remotePID = nil }
        return remotePID
    }

    private func finish(error: Error?) {
        isInterrupting = false
        guard !isStopping else { return }
        AgentReducer.finished(error: error?.userMessage, to: &state)
    }
}
