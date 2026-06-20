//
//  ClaudeAgentSession.swift
//  Argos
//
//  Controlador en vivo de una sesión de agente Claude Code remota. Análogo a
//  `LiveTerminalController` pero para el canal exec + protocolo stream-json:
//   - stdout del proceso -> NDJSON -> eventos -> `AgentReducer` -> `state` (observable)
//   - acciones del usuario (prompt / decisión de permiso) -> stdin del proceso
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
    private(set) var state = AgentConversationState()

    /// Directorio de trabajo remoto donde corre el agente (informativo para la UI).
    let workingDirectory: String

    private let service: any SSHServicing
    private let command: String

    private var task: Task<Void, Never>?
    private var isStopping = false

    // Stream de stdin (prompts y control_response). `let` Sendable: se puede encolar
    // desde cualquier método sin cruzar de actor.
    private let stdinStream: AsyncStream<[UInt8]>
    private let stdinContinuation: AsyncStream<[UInt8]>.Continuation

    init(service: any SSHServicing, command: String, workingDirectory: String) {
        self.service = service
        self.command = command
        self.workingDirectory = workingDirectory
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        self.stdinStream = stream
        self.stdinContinuation = continuation
        start()
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
                        guard let event = AgentProtocol.decode(line: line) else { continue }
                        guard let self else { continue }
                        AgentReducer.apply(event, to: &self.state)
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

    /// Detiene el agente: finaliza stdin (EOF -> el proceso remoto sale) y cancela.
    func stop() {
        isStopping = true
        stdinContinuation.finish()
        task?.cancel()
        task = nil
    }

    private func finish(error: Error?) {
        guard !isStopping else { return }
        AgentReducer.finished(error: error?.userMessage, to: &state)
    }
}
