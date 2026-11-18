//
//  PersistentAgentSession.swift
//  Argos
//
//  Cliente de un agente persistente (ver `PersistentAgentScript`). El agente corre en
//  el servidor; esta clase solo se ENGANCHA a su log para pintar la conversación y le
//  escribe por la FIFO. Desengancharse (segundo plano, cerrar la vista, perder la red)
//  no para al agente; volver a engancharse sigue el log desde el último byte leído
//  (incremental) y, si el flujo se corta con la vista abierta, reintenta solo.
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
    /// Se QUIERE estar enganchado (la vista está abierta), aunque el canal esté
    /// reconectando. El estado real de la conexión es `link`.
    private(set) var isAttached = false
    private(set) var link: AgentLinkState = .detached
    /// Reanudando (arrancando claude con `--resume`).
    private(set) var isResuming = false
    /// Se pidió interrumpir el turno y aún no llegó su `result`.
    private(set) var isInterrupting = false
    /// Bytes ABSOLUTOS del log ya procesados (hasta la última línea completa): lo que el
    /// usuario ya ha visto. Los avisos en segundo plano solo avisan de lo posterior, y el
    /// siguiente enganche sigue desde aquí.
    @ObservationIgnored private(set) var receivedBytes = 0
    var lastError: String?

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var startupWatch: Task<Void, Never>?
    /// Igual que en el terminal: un `tail` viejo que termina tarde no debe tocar el
    /// estado del enganche actual.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var keepOpen: AsyncStream<[UInt8]>.Continuation?
    /// Tamaño del log según el último listado (sin haberlo leído aún).
    @ObservationIgnored private var listedLogBytes: Int
    @ObservationIgnored private let hibernation: () -> PersistentAgentHibernation
    /// Todo mensaje va por la entrada estándar del canal, también los cortos (que si no
    /// viajan en base64 dentro del comando). Lo activan los atajos: el encargo no debe
    /// aparecer en la lista de procesos del servidor.
    @ObservationIgnored var sendsOnlyViaStdin = false

    init(
        service: any SSHServicing,
        info: PersistentAgentInfo,
        hibernation: @escaping () -> PersistentAgentHibernation = { AgentHibernationPreferences.current() }
    ) {
        self.service = service
        self.id = info.id
        self.meta = info.meta
        self.isAlive = info.isAlive
        self.listedLogBytes = info.logBytes
        self.hibernation = hibernation
    }

    /// Sesión que ya muestra `state` y ha leído `receivedBytes` del log (la que se crea al
    /// pasar al servidor una conversación del Mac: su log empieza con esa conversación).
    convenience init(
        service: any SSHServicing,
        info: PersistentAgentInfo,
        seededState: AgentConversationState,
        receivedBytes: Int,
        hibernation: @escaping () -> PersistentAgentHibernation = { AgentHibernationPreferences.current() }
    ) {
        self.init(service: service, info: info, hibernation: hibernation)
        self.state = seededState
        self.receivedBytes = max(0, receivedBytes)
    }

    // MARK: - Crear / reanudar

    /// Lanza un agente nuevo en `workingDirectory` y devuelve su sesión (aún sin enganchar).
    static func launch(
        service: any SSHServicing,
        workingDirectory: String,
        title: String,
        permissionMode: ClaudeAgentCommand.PermissionMode = .default,
        oauthToken: String? = KeychainStore.claudeOAuthToken(),
        hibernation: PersistentAgentHibernation = AgentHibernationPreferences.current()
    ) async throws -> PersistentAgentSession {
        let id = UUID().uuidString.lowercased()
        let meta = PersistentAgentMeta(workingDirectory: workingDirectory, title: title, createdAt: Date(), permissionMode: permissionMode.rawValue)
        let launched = try await start(service: service, id: id, meta: meta, resume: false, oauthToken: oauthToken, hibernation: hibernation)
        let session = PersistentAgentSession(
            service: service,
            info: PersistentAgentInfo(id: id, isAlive: true, logBytes: 0, meta: meta),
            hibernation: { hibernation }
        )
        if launched { session.watchStartup() }
        return session
    }

    /// Relanza el proceso (tras reiniciarse el servidor o hibernar) y se vuelve a
    /// enganchar. Con conversación usa `--resume`; un agente que nunca recibió nada no
    /// tiene sesión que reanudar y arranca con su mismo id.
    @discardableResult
    func resume(oauthToken: String? = KeychainStore.claudeOAuthToken()) async -> Bool {
        isResuming = true
        defer { isResuming = false }
        var fresh = meta
        fresh.hibernatedAt = nil
        let hasConversation = max(listedLogBytes, receivedBytes) > 0 || !state.items.isEmpty
        do {
            let launched = try await Self.start(
                service: service, id: id, meta: fresh, resume: hasConversation,
                oauthToken: oauthToken, hibernation: hibernation()
            )
            if launched { watchStartup() }
            meta = fresh
            isAlive = true
            lastError = nil
            // Solo si la vista seguía abierta: reanudar no debe reengancharse a escondidas.
            if isAttached { attach() }
            return true
        } catch {
            lastError = error.userMessage
            return false
        }
    }

    /// `claudePath`: ruta ya conocida del binario (si no, se busca en el servidor).
    /// Devuelve `true` si lanzó un proceso nuevo (`false` si ya estaba vivo).
    @discardableResult
    static func start(
        service: any SSHServicing,
        id: String,
        meta: PersistentAgentMeta,
        resume: Bool,
        oauthToken: String?,
        hibernation: PersistentAgentHibernation,
        claudePath knownPath: String? = nil
    ) async throws -> Bool {
        let located: String?
        if let knownPath { located = knownPath } else { located = try await service.locateClaude() }
        guard let claudePath = located else {
            throw PersistentAgentError.claudeMissing
        }
        let invocation = ClaudeAgentCommand.persistent(
            claudePath: claudePath, sessionID: id, resume: resume, permissionMode: meta.resolvedPermissionMode
        )
        let command = try PersistentAgentScript.launch(
            id: id, meta: meta, claudeInvocation: invocation, hibernation: hibernation
        )
        // El token va por stdin (primera línea), nunca en la línea de comandos.
        let reply = try await AgentStdinExchange.firstLine(
            service: service, command: command, input: ClaudeAgentCommand.tokenLine(oauthToken),
            timeout: .seconds(60), accept: isLaunchReply
        )
        try parseLaunchReply(reply)
        return reply != PersistentAgentScript.aliveReply
    }

    /// Plazos (acumulados: 2, 6 y 12 s) en los que se vuelve a mirar si el claude recién
    /// lanzado sigue vivo. El lanzador solo espera 1 s: en un servidor cargado, un claude
    /// que no puede arrancar (opción desconocida, sin sesión…) tarda más en morir y el
    /// lanzador ya lo habría dado por arrancado. Sin una señal positiva de «arrancó bien»
    /// (en stream-json claude no escribe nada hasta recibir un mensaje) se comprueba aquí,
    /// con margen y sin retrasar el arranque.
    static let startupChecks: [Duration] = [.seconds(2), .seconds(4), .seconds(6)]

    /// Tras lanzar: si el proceso muere al poco, lo marca como parado y muestra el porqué
    /// (final de `err.log`), igual que si el lanzador lo hubiera visto morir.
    func watchStartup(checks: [Duration] = PersistentAgentSession.startupChecks) {
        startupWatch?.cancel()
        startupWatch = Task { [weak self] in
            for delay in checks {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                guard await self.refreshInfo() else { continue }
                guard !self.isAlive else { continue }
                let tail = (try? await self.service.runAgentScript(PersistentAgentScript.errorTail(id: self.id))) ?? ""
                self.lastError = PersistentAgentError.launchFailed(String(tail.suffix(PersistentAgentScript.errorTailBytes))).userMessage
                return
            }
        }
    }

    /// ¿Es `line` una respuesta del lanzador? (lo demás es ruido del perfil del shell)
    nonisolated static func isLaunchReply(_ line: String) -> Bool {
        line == PersistentAgentScript.busyReply || line == PersistentAgentScript.aliveReply
            || line.hasPrefix(PersistentAgentScript.failedReply) || Int32(line) != nil
    }

    /// Interpreta la primera línea del lanzador.
    nonisolated static func parseLaunchReply(_ reply: String) throws {
        if reply == PersistentAgentScript.busyReply { throw PersistentAgentError.busy }
        if reply.hasPrefix(PersistentAgentScript.failedReply) {
            let encoded = reply.dropFirst(PersistentAgentScript.failedReply.count).trimmingCharacters(in: .whitespaces)
            let detail = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw PersistentAgentError.launchFailed(String(detail.suffix(PersistentAgentScript.errorTailBytes)))
        }
        guard reply == PersistentAgentScript.aliveReply || Int32(reply) != nil else {
            throw AgentExecError(message: String(localized: "No se pudo arrancar el agente en el servidor (respuesta: \(String(reply.prefix(200))))."))
        }
    }

    // MARK: - Enganche al log

    /// (Re)engancha siguiendo el log desde lo último leído: la conversación se conserva y
    /// solo llega lo nuevo. Si el servidor rotó el log por delante, se reconstruye.
    func attach() {
        isAttached = true
        connect(attempt: 0)
    }

    /// «Recargar»: olvida lo leído y reconstruye la conversación desde el principio.
    func reload() {
        detach()
        state = AgentConversationState()
        receivedBytes = 0
        attach()
    }

    /// Deja de leer el log. El agente sigue trabajando en el servidor.
    func detach() {
        isAttached = false
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        keepOpen?.finish()
        keepOpen = nil
        task?.cancel()
        task = nil
        link = .detached
    }

    private func connect(attempt: Int) {
        generation += 1
        let current = generation
        retryTask?.cancel()
        retryTask = nil
        keepOpen?.finish()
        task?.cancel()
        link = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)

        let (outputStream, output) = AsyncStream<[UInt8]>.makeStream()
        // stdin que nunca se cierra: `runAgentExec` termina si su stdin acaba.
        let (stdin, keepOpen) = AsyncStream<[UInt8]>.makeStream()
        self.keepOpen = keepOpen
        let service = self.service
        let command = PersistentAgentScript.attach(id: id, fromByte: receivedBytes + 1)
        let requested = receivedBytes

        task = Task { [weak self] in
            let parser = Task { @MainActor [weak self] in
                var buffer = NDJSONLineBuffer()
                var stream = AgentAttachStreamParser()
                for await chunk in outputStream {
                    guard let self, self.generation == current else { continue }
                    if !self.link.isLive { self.link = .live }
                    for line in buffer.appendCountingBytes(chunk) {
                        guard self.generation == current else { break }
                        switch stream.classify(text: line.text) {
                        case .noise:
                            continue
                        case .header(let base, let from):
                            self.adoptLogBase((base, from), requested: requested)
                        case .data:
                            self.receivedBytes += line.byteCount
                            guard let text = line.text, let event = AgentProtocol.decode(line: text) else { continue }
                            AgentReducer.apply(event, to: &self.state, echoesUserMessages: true)
                            if case .result = event { self.isInterrupting = false }
                        case .rotated:
                            self.logWasRotated(generation: current)
                        }
                    }
                }
            }
            var failure: Error?
            do {
                try await service.runAgentExec(command: command, stdin: stdin, output: output)
            } catch is CancellationError {
                // Desenganche normal.
            } catch {
                failure = error
            }
            await parser.value
            self?.connectionEnded(generation: current, attempt: attempt, error: failure)
        }
    }

    /// La cabecera dice desde qué byte absoluto sigue el log. Si no es justo después de lo
    /// ya leído (el servidor rotó lo que faltaba), se reconstruye desde ahí.
    private func adoptLogBase(_ header: (base: Int, from: Int), requested: Int) {
        let start = header.base + header.from - 1
        guard start != requested else { return }
        Log.agent.notice("El log del agente se rotó: se reconstruye la conversación desde lo conservado.")
        state = AgentConversationState()
        receivedBytes = start
    }

    /// El servidor va a sustituir el log (rotación al reanudar): lo que siga en ESTE
    /// enganche es la copia conservada, que ya tenemos. Se corta y se reengancha desde lo
    /// leído (que no incluye la marca: sus bytes no cuentan).
    private func logWasRotated(generation rotated: Int) {
        guard rotated == generation, isAttached else { return }
        Log.agent.notice("El log del agente se va a rotar: se reengancha.")
        generation += 1
        let pending = generation
        keepOpen?.finish()
        task?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: AgentAttachStreamParser.rotationSettleDelay)
            guard !Task.isCancelled, let self, self.isAttached, self.generation == pending else { return }
            self.connect(attempt: 0)
        }
    }

    private func connectionEnded(generation ended: Int, attempt: Int, error: Error?) {
        guard ended == generation, isAttached else { return }
        if let error {
            Log.agent.notice("Se cortó el log del agente: \(error.localizedDescription, privacy: .private)")
        }
        // Con la vista abierta se reintenta solo, cada vez más espaciado.
        let next = attempt + 1
        link = .reconnecting(attempt: next)
        let delay = AgentReconnectPolicy.delaySeconds(attempt: next)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isAttached, self.generation == ended else { return }
            self.connect(attempt: next)
        }
    }

    // MARK: - Acciones

    /// Envía un mensaje. El texto solo debe borrarse del campo con `.sent`. Si el agente
    /// estaba hibernado, se reanuda solo (salvo en un modo que actúa sin preguntar, que
    /// pide confirmación: ver `PersistentAgentMeta.resumeRequiresConfirmation`).
    @discardableResult
    ///
    /// `resumeGuard` (atajos): se consulta con el `meta.json` vigente justo antes de CADA
    /// reanudación; si dice que no, no se reanuda y se devuelve `.needsResumeConfirmation`
    /// (el modo cambió desde que el usuario lo aprobó).
    func send(
        _ rawText: String,
        confirmedResume: Bool = false,
        resumeGuard: ((PersistentAgentMeta) -> Bool)? = nil
    ) async -> AgentSendOutcome {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed }
        if !isAlive, meta.isHibernated || confirmedResume {
            if meta.resumeRequiresConfirmation && !confirmedResume { return .needsResumeConfirmation }
            if let resumeGuard, !resumeGuard(meta) { return .needsResumeConfirmation }
            guard await resume() else { return .failed }
        }
        var sent = await write(AgentProtocol.encodeUserMessage(text: text), answering: nil)
        if !sent, !isAlive, await refreshInfo(), meta.isHibernated {
            // Lo hibernó el vigilante mientras mirabas: se reanuda y se reintenta.
            if meta.resumeRequiresConfirmation && !confirmedResume { return .needsResumeConfirmation }
            if let resumeGuard, !resumeGuard(meta) { return .needsResumeConfirmation }
            if await resume() {
                sent = await write(AgentProtocol.encodeUserMessage(text: text), answering: nil)
            }
        }
        if sent, state.status != .working { state.status = .working }
        return sent ? .sent : .failed
    }

    /// El permiso pendiente solo se retira si la respuesta LLEGÓ al agente: si el envío
    /// falla (mala cobertura), el aviso sigue ahí para reintentar en vez de dejar al
    /// agente bloqueado sin que se vea por qué.
    func respond(to request: AgentPermissionRequest, decision: AgentPermissionDecision) async {
        let sent = await write(
            AgentProtocol.encodePermissionResponse(requestID: request.id, decision: decision),
            answering: request.id
        )
        // Con el agente parado ya no hay a quién responder: tampoco se deja la tarjeta.
        if sent || !isAlive, state.pendingPermission?.id == request.id { state.pendingPermission = nil }
    }

    func allowPendingPermission() async {
        guard let request = state.pendingPermission else { return }
        await respond(to: request, decision: .allow(updatedInput: request.input))
    }

    func denyPendingPermission() async {
        guard let request = state.pendingPermission else { return }
        await respond(to: request, decision: .deny(message: "El usuario denegó esta acción."))
    }

    /// «Detener» el turno en curso: la petición de control `interrupt` por la FIFO (como
    /// en el panel del Mac). El agente sigue vivo; el CLI cierra el turno con un `result`.
    func interrupt() async {
        // Con un permiso pendiente no: se deniega (y queda anotado en el log para los
        // demás dispositivos), en vez de dejar en el log un permiso que nadie respondió.
        guard isAlive, state.status == .working, state.pendingPermission == nil, !isInterrupting else { return }
        isInterrupting = true
        let requestID = "argos-interrupt-\(UUID().uuidString.lowercased())"
        if !(await write(AgentProtocol.encodeInterrupt(requestID: requestID), answering: nil)) {
            isInterrupting = false
        }
    }

    /// «Poner en reposo» a demanda: para el proceso SI en el servidor está quieto (su
    /// último evento es un `result`); escribirle lo reanuda. Devuelve si lo hizo.
    @discardableResult
    func hibernateNow() async -> Bool {
        do {
            let output = try await service.runAgentScript(PersistentAgentScript.hibernate(id: id, minIdleSeconds: 0))
            let done = output.contains("\(PersistentAgentScript.hibernatedReply) \(id)")
            await refreshInfo()
            if done {
                lastError = nil
            } else if isAlive {
                lastError = String(localized: "Claude está trabajando o espera un permiso: no se puede poner en reposo ahora.")
            }
            return done
        } catch {
            lastError = error.userMessage
            return false
        }
    }

    /// Para el proceso del agente (la conversación se puede reanudar después). Con
    /// `delete`, borra también su log (solo si el proceso murió de verdad).
    @discardableResult
    func stop(delete: Bool = false) async -> Bool {
        do {
            _ = try await service.runAgentScript(PersistentAgentScript.stop(id: id, delete: delete))
            isAlive = false
            isInterrupting = false
            if delete { detach() }
            return true
        } catch {
            lastError = error.userMessage
            return false
        }
    }

    /// Relee del servidor si sigue vivo y su `meta.json` (p. ej. si se hibernó).
    @discardableResult
    func refreshInfo() async -> Bool {
        do {
            guard let info = try await Self.list(service: service).first(where: { $0.id == id }) else { return false }
            meta = info.meta
            isAlive = info.isAlive
            listedLogBytes = info.logBytes
            return true
        } catch {
            Log.agent.notice("No se pudo releer el agente: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// Devuelve si la línea llegó al agente.
    private func write(_ line: String, answering requestID: String?) async -> Bool {
        do {
            try await deliver(line, answering: requestID)
            lastError = nil
            return true
        } catch PersistentAgentError.notRunning {
            isAlive = false
            lastError = await notRunningMessage()
        } catch {
            lastError = error.userMessage
        }
        return false
    }

    /// Las líneas pequeñas van dentro del comando; las grandes, por stdin (límite de
    /// 128 KiB por argumento), con comprobación de que llegaron enteras.
    private func deliver(_ line: String, answering requestID: String?) async throws {
        guard sendsOnlyViaStdin || PersistentAgentScript.needsStdin(line: line) else {
            _ = try await service.runAgentScript(
                PersistentAgentScript.send(id: id, line: line, answeredRequestID: requestID)
            )
            return
        }
        let bytes = Array((line + "\n").utf8)
        let replies = [
            PersistentAgentScript.sentReply, PersistentAgentScript.deadReply,
            PersistentAgentScript.shortReply, PersistentAgentScript.timeoutReply, PersistentAgentScript.busyReply,
        ]
        let reply = try await AgentStdinExchange.firstLine(
            service: service,
            command: PersistentAgentScript.sendViaStdin(id: id, byteCount: bytes.count, answeredRequestID: requestID),
            input: bytes,
            timeout: .seconds(PersistentAgentScript.sendTimeoutSeconds + 30),
            accept: { replies.contains($0) }
        )
        switch reply {
        case PersistentAgentScript.sentReply: return
        case PersistentAgentScript.deadReply: throw PersistentAgentError.notRunning
        case PersistentAgentScript.shortReply: throw PersistentAgentError.truncatedSend
        case PersistentAgentScript.busyReply: throw PersistentAgentError.sendBusy
        default: throw AgentExchangeTimeout()
        }
    }

    /// «No está en marcha» + el final de `err.log` (por qué murió), si lo hay.
    private func notRunningMessage() async -> String {
        let base = PersistentAgentError.notRunning.userMessage
        guard let tail = try? await service.runAgentScript(PersistentAgentScript.errorTail(id: id))
            .trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty else { return base }
        return String(localized: "\(base)\nÚltimo mensaje del servidor:\n\(String(tail.suffix(600)))")
    }

    /// Acción explícita del usuario (enviar, reanudar, recargar): olvida el bloqueo de la
    /// conexión por credenciales rechazadas o host key cambiada para volver a intentarlo.
    func liftConnectionBlock() async {
        await service.resetConnectionHealth()
    }

    // MARK: - Listado

    static func list(service: any SSHServicing) async throws -> [PersistentAgentInfo] {
        PersistentAgentScript.parseList(try await service.runAgentScript(PersistentAgentScript.list()))
    }
}
