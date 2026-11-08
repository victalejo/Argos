//
//  PersistentAgentSession.swift
//  Argos
//
//  Cliente de un agente persistente (ver `PersistentAgentScript`). El agente corre en
//  el servidor; esta clase solo se ENGANCHA a su log para pintar la conversación y le
//  escribe por la FIFO. Desengancharse (segundo plano, cerrar la vista, perder la red)
//  no para al agente; volver a engancharse relee el log y reconstruye todo.
//

import Foundation
import Observation

@MainActor
@Observable
final class PersistentAgentSession {

    let id: String
    private(set) var meta: PersistentAgentMeta
    private(set) var state = AgentConversationState()
    /// `false` si el proceso de claude terminó (se puede reanudar).
    private(set) var isAlive: Bool
    private(set) var isAttached = false
    /// Bytes del log leídos en el enganche actual (desde el byte 1): lo que el usuario ya
    /// ha visto. Los avisos en segundo plano solo avisan de lo posterior.
    @ObservationIgnored private(set) var receivedBytes = 0
    var lastError: String?

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Igual que en el terminal: un `tail` viejo que termina tarde no debe tocar el
    /// estado del enganche actual.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var keepOpen: AsyncStream<[UInt8]>.Continuation?

    init(service: any SSHServicing, info: PersistentAgentInfo) {
        self.service = service
        self.id = info.id
        self.meta = info.meta
        self.isAlive = info.isAlive
    }

    // MARK: - Crear / reanudar

    /// Lanza un agente nuevo en `workingDirectory` y devuelve su sesión (aún sin enganchar).
    static func launch(
        service: any SSHServicing,
        workingDirectory: String,
        title: String,
        permissionMode: ClaudeAgentCommand.PermissionMode = .default,
        oauthToken: String? = KeychainStore.claudeOAuthToken()
    ) async throws -> PersistentAgentSession {
        let id = UUID().uuidString.lowercased()
        let meta = PersistentAgentMeta(workingDirectory: workingDirectory, title: title, createdAt: Date(), permissionMode: permissionMode.rawValue)
        try await start(service: service, id: id, meta: meta, resume: false, oauthToken: oauthToken)
        return PersistentAgentSession(
            service: service,
            info: PersistentAgentInfo(id: id, isAlive: true, logBytes: 0, meta: meta)
        )
    }

    /// Relanza el proceso con `--resume` (p. ej. tras reiniciarse el servidor) y se
    /// vuelve a enganchar.
    func resume(oauthToken: String? = KeychainStore.claudeOAuthToken()) async {
        do {
            try await Self.start(service: service, id: id, meta: meta, resume: true, oauthToken: oauthToken)
            isAlive = true
            lastError = nil
            attach()
        } catch {
            lastError = error.userMessage
        }
    }

    private static func start(
        service: any SSHServicing,
        id: String,
        meta: PersistentAgentMeta,
        resume: Bool,
        oauthToken: String?
    ) async throws {
        guard let claudePath = try await service.locateClaude() else {
            throw PersistentAgentError.claudeMissing
        }
        let invocation = ClaudeAgentCommand.persistent(
            claudePath: claudePath, sessionID: id, resume: resume, permissionMode: meta.resolvedPermissionMode
        )
        let command = try PersistentAgentScript.launch(id: id, meta: meta, claudeInvocation: invocation)

        // El token va por stdin (primera línea), nunca en la línea de comandos. stdin se
        // cierra en cuanto el lanzador responde (PID o «ya vivo»).
        let (stdin, input) = AsyncStream<[UInt8]>.makeStream()
        input.yield(ClaudeAgentCommand.tokenLine(oauthToken))
        let (outputStream, output) = AsyncStream<[UInt8]>.makeStream()
        let run = Task { try await service.runAgentExec(command: command, stdin: stdin, output: output) }
        var reply = ""
        for await chunk in outputStream {
            reply += String(decoding: chunk, as: UTF8.self)
            if reply.contains("\n") { break }
        }
        input.finish()
        _ = try? await run.value
        let firstLine = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if firstLine == "ARGOS_AGENT_BUSY" { throw PersistentAgentError.busy }
        guard firstLine == "ARGOS_AGENT_ALIVE" || Int32(firstLine) != nil else {
            throw AgentExecError(message: "No se pudo arrancar el agente en el servidor.")
        }
    }

    // MARK: - Enganche al log

    /// (Re)engancha: vacía la conversación y relee el log desde el principio.
    func attach() {
        detach()
        generation += 1
        let current = generation
        state = AgentConversationState()
        receivedBytes = 0
        isAttached = true

        let (outputStream, output) = AsyncStream<[UInt8]>.makeStream()
        // stdin que nunca se cierra: `runAgentExec` termina si su stdin acaba.
        let (stdin, keepOpen) = AsyncStream<[UInt8]>.makeStream()
        self.keepOpen = keepOpen
        let service = self.service
        let command = PersistentAgentScript.attach(id: id)

        task = Task { [weak self] in
            let parser = Task { @MainActor [weak self] in
                var buffer = NDJSONLineBuffer()
                for await chunk in outputStream {
                    guard let self, self.generation == current else { continue }
                    self.receivedBytes += chunk.count
                    for line in buffer.append(chunk) {
                        guard let event = AgentProtocol.decode(line: line) else { continue }
                        AgentReducer.apply(event, to: &self.state, echoesUserMessages: true)
                    }
                }
            }
            do {
                try await service.runAgentExec(command: command, stdin: stdin, output: output)
            } catch is CancellationError {
                // Desenganche normal.
            } catch {
                if let self, self.generation == current { self.lastError = error.userMessage }
            }
            parser.cancel()
            if let self, self.generation == current { self.isAttached = false }
        }
    }

    /// Deja de leer el log. El agente sigue trabajando en el servidor.
    func detach() {
        generation += 1
        keepOpen?.finish()
        keepOpen = nil
        task?.cancel()
        task = nil
        isAttached = false
    }

    // MARK: - Acciones

    func send(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await write(AgentProtocol.encodeUserMessage(text: text), answering: nil)
        if lastError == nil, state.status != .working { state.status = .working }
    }

    func respond(to request: AgentPermissionRequest, decision: AgentPermissionDecision) async {
        await write(AgentProtocol.encodePermissionResponse(requestID: request.id, decision: decision), answering: request.id)
        if state.pendingPermission?.id == request.id { state.pendingPermission = nil }
    }

    func allowPendingPermission() async {
        guard let request = state.pendingPermission else { return }
        await respond(to: request, decision: .allow(updatedInput: request.input))
    }

    func denyPendingPermission() async {
        guard let request = state.pendingPermission else { return }
        await respond(to: request, decision: .deny(message: "El usuario denegó esta acción."))
    }

    /// Para el proceso del agente (la conversación se puede reanudar después). Con
    /// `delete`, borra también su log.
    func stop(delete: Bool = false) async {
        do {
            _ = try await service.runAgentScript(PersistentAgentScript.stop(id: id, delete: delete))
            isAlive = false
            if delete { detach() }
        } catch {
            lastError = error.userMessage
        }
    }

    private func write(_ line: String, answering requestID: String?) async {
        do {
            _ = try await service.runAgentScript(
                PersistentAgentScript.send(id: id, line: line, answeredRequestID: requestID)
            )
            lastError = nil
        } catch PersistentAgentError.notRunning {
            isAlive = false
            lastError = PersistentAgentError.notRunning.userMessage
        } catch {
            lastError = error.userMessage
        }
    }

    // MARK: - Listado

    static func list(service: any SSHServicing) async throws -> [PersistentAgentInfo] {
        PersistentAgentScript.parseList(try await service.runAgentScript(PersistentAgentScript.list()))
    }
}
