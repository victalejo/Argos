package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/** Estado observable de un [PersistentAgentSession]. */
data class PersistentAgentSessionState(
    val meta: PersistentAgentMeta,
    val conversation: AgentConversationState = AgentConversationState(),
    /** `false` si el proceso de claude terminó (se puede reanudar). */
    val isAlive: Boolean,
    /** Se QUIERE estar enganchado (la vista está abierta), aunque el canal esté reconectando. */
    val isAttached: Boolean = false,
    /** Estado REAL de la conexión al log. */
    val link: AgentLinkState = AgentLinkState.Detached,
    /** Reanudando (arrancando claude con `--resume`). */
    val isResuming: Boolean = false,
    /** Se pidió interrumpir el turno y aún no llegó su `result`. */
    val isInterrupting: Boolean = false,
    /**
     * Bytes ABSOLUTOS del log ya procesados (hasta la última línea completa): lo que el usuario
     * ya ha visto. El siguiente enganche sigue desde aquí.
     */
    val receivedBytes: Long = 0,
    val lastError: String? = null,
)

/**
 * Cliente de un agente persistente (port de `PersistentAgentSession.swift`). El agente corre en
 * el servidor; esta clase solo se ENGANCHA a su log para pintar la conversación y le escribe por
 * la FIFO. Desengancharse no para al agente; volver a engancharse sigue el log desde el último
 * byte leído (incremental) y, si el flujo se corta con la vista abierta, reintenta solo.
 *
 * [scope] es del dueño (p. ej. `viewModelScope`): al cancelarlo se desengancha. [hibernation]
 * da el plazo de reposo vigente (preferencia del dispositivo) al lanzar o reanudar. Por defecto
 * ([autoReconnect] `false`) un corte deja `isAttached = false` y reintentar es cosa del dueño (la
 * vista de Android lleva su propia espera y su botón «Reconectar»); con `true` se reintenta solo
 * con [AgentReconnectPolicy], como en Apple.
 */
class PersistentAgentSession(
    private val service: SSHServicing,
    private val exec: AgentExecStreaming,
    info: PersistentAgentInfo,
    private val scope: CoroutineScope,
    private val autoReconnect: Boolean = false,
    private val hibernation: () -> PersistentAgentHibernation = { PersistentAgentHibernation.STANDARD },
) {
    val id: String = info.id

    private val mutableState = MutableStateFlow(PersistentAgentSessionState(meta = info.meta, isAlive = info.isAlive))
    val state: StateFlow<PersistentAgentSessionState> = mutableState.asStateFlow()

    /** Un `tail` viejo que termina tarde no debe tocar el estado del enganche actual. */
    private val generation = AtomicInteger(0)

    /** Tamaño del log según el último listado (sin haberlo leído aún). */
    @Volatile
    private var listedLogBytes: Long = info.logBytes

    @Volatile
    private var job: Job? = null

    @Volatile
    private var retryJob: Job? = null

    @Volatile
    private var startupJob: Job? = null

    // MARK: Crear / reanudar

    /**
     * Relanza el proceso (tras reiniciarse el servidor o hibernar) y se vuelve a enganchar si la
     * vista seguía abierta. Con conversación usa `--resume`; un agente que nunca recibió nada no
     * tiene sesión que reanudar y arranca con su mismo id (`--session-id`).
     */
    suspend fun resume(oauthToken: String?): Boolean {
        mutableState.update { it.copy(isResuming = true) }
        try {
            val current = mutableState.value
            val fresh = current.meta.copy(hibernatedAt = null)
            val hasConversation = maxOf(listedLogBytes, current.receivedBytes) > 0 || current.conversation.items.isNotEmpty()
            val launched = start(service, exec, id, fresh, hasConversation, oauthToken, hibernation())
            if (launched) watchStartup()
            mutableState.update { it.copy(meta = fresh, isAlive = true, lastError = null) }
            // Solo si la vista seguía abierta: reanudar no debe reengancharse a escondidas.
            if (mutableState.value.isAttached) attach()
            return true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            mutableState.update { it.copy(lastError = error.userMessage) }
            return false
        } finally {
            mutableState.update { it.copy(isResuming = false) }
        }
    }

    /**
     * Tras lanzar: si el proceso muere al poco, lo marca como parado y muestra el porqué (final
     * de `err.log`), igual que si el lanzador lo hubiera visto morir. El lanzador solo espera 1 s:
     * en un servidor cargado, un claude que no puede arrancar tarda más en morir y el lanzador ya
     * lo habría dado por arrancado. Se vuelve a mirar a los plazos [checksMillis] (acumulados: 2, 6
     * y 12 s, como `PersistentAgentSession.watchStartup()` de Swift) sin retrasar el arranque.
     */
    fun watchStartup(checksMillis: List<Long> = STARTUP_CHECKS_MILLIS) {
        startupJob?.cancel()
        startupJob = scope.launch {
            for (wait in checksMillis) {
                delay(wait)
                if (!refreshInfo() || mutableState.value.isAlive) continue
                val tail = try {
                    service.runAgentScript(PersistentAgentScript.errorTail(id))
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    ""
                }
                val message = PersistentAgentError.LAUNCH_FAILED.describe(tail.takeLast(PersistentAgentScript.ERROR_TAIL_BYTES))
                mutableState.update { it.copy(lastError = message) }
                return@launch
            }
        }
    }

    // MARK: Enganche al log

    /**
     * (Re)engancha siguiendo el log desde lo último leído: la conversación se conserva y solo
     * llega lo nuevo. Si el servidor rotó el log por delante, se reconstruye.
     */
    fun attach() {
        mutableState.update { it.copy(isAttached = true) }
        connect(attempt = 0)
    }

    /** «Recargar»: olvida lo leído y reconstruye la conversación desde el principio. */
    fun reload() {
        forget()
        attach()
    }

    /** Se desengancha y olvida lo leído: el siguiente [attach] reconstruye desde el principio. */
    fun forget() {
        detach()
        mutableState.update { it.copy(conversation = AgentConversationState(), receivedBytes = 0) }
    }

    /** Deja de leer el log. El agente sigue trabajando en el servidor. */
    fun detach() {
        generation.incrementAndGet()
        retryJob?.cancel()
        retryJob = null
        job?.cancel()
        job = null
        mutableState.update { it.copy(isAttached = false, link = AgentLinkState.Detached) }
    }

    private fun connect(attempt: Int) {
        val current = generation.incrementAndGet()
        retryJob?.cancel()
        retryJob = null
        job?.cancel()
        val requested = mutableState.value.receivedBytes
        mutableState.update {
            it.copy(link = if (attempt == 0) AgentLinkState.Connecting else AgentLinkState.Reconnecting(attempt))
        }
        val command = PersistentAgentScript.attach(id, requested + 1)
        job = scope.launch {
            var buffer = NdjsonLineBuffer()
            val parser = AgentAttachStreamParser()
            val failure = try {
                // stdin que no termina nunca: si acabara, `runAgentExec` terminaría también.
                val keepOpen = flow<ByteArray> { awaitCancellation() }
                exec.runAgentExec(command, keepOpen) { chunk ->
                    if (generation.get() == current) {
                        val appended = buffer.appendCountingBytes(chunk)
                        buffer = appended.buffer
                        handle(current, requested, parser, appended.lines)
                    }
                }
                null
            } catch (cancelled: CancellationException) {
                // Lo cancelamos nosotros (reenganche, detach) tras cambiar la generación: no se
                // toca nada. Si cancelan el scope del dueño, el enganche se da por terminado.
                updateIfCurrent(current) { it.copy(isAttached = false, link = AgentLinkState.Detached) }
                throw cancelled
            } catch (error: Exception) {
                error
            }
            connectionEnded(current, attempt, failure)
        }
    }

    private fun handle(current: Int, requested: Long, parser: AgentAttachStreamParser, lines: List<NdjsonLineBuffer.CountedLine>) {
        updateIfCurrent(current) { if (it.link == AgentLinkState.Live) it else it.copy(link = AgentLinkState.Live) }
        for (line in lines) {
            if (generation.get() != current) return
            when (val kind = parser.classify(line.text)) {
                AgentAttachStreamParser.Line.Noise -> Unit
                is AgentAttachStreamParser.Line.Header -> adoptLogBase(current, kind, requested)
                AgentAttachStreamParser.Line.Data -> updateIfCurrent(current) { state ->
                    val event = line.text?.let(AgentProtocol::decode)
                    val conversation = event?.let { AgentReducer.apply(it, state.conversation, echoesUserMessages = true) }
                        ?: state.conversation
                    state.copy(
                        conversation = conversation,
                        receivedBytes = state.receivedBytes + line.byteCount,
                        isInterrupting = state.isInterrupting && event !is AgentStreamEvent.Result,
                    )
                }
                AgentAttachStreamParser.Line.Rotated -> {
                    logWasRotated(current)
                    return
                }
            }
        }
    }

    /**
     * La cabecera dice desde qué byte absoluto sigue el log. Si no es justo después de lo ya leído
     * (el servidor rotó lo que faltaba), se reconstruye desde ahí.
     */
    private fun adoptLogBase(current: Int, header: AgentAttachStreamParser.Line.Header, requested: Long) {
        val start = header.base + header.from - 1
        if (start == requested) return
        updateIfCurrent(current) { it.copy(conversation = AgentConversationState(), receivedBytes = start) }
    }

    /**
     * El servidor va a sustituir el log (rotación al reanudar): lo que siga en ESTE enganche es la
     * copia conservada, que ya tenemos. Se corta y se reengancha desde lo leído (que no incluye la
     * marca: sus bytes no cuentan).
     */
    private fun logWasRotated(rotated: Int) {
        if (rotated != generation.get() || !mutableState.value.isAttached) return
        val pending = generation.incrementAndGet()
        job?.cancel()
        retryJob = scope.launch {
            delay(AgentAttachStreamParser.ROTATION_SETTLE_DELAY_MILLIS)
            if (mutableState.value.isAttached && generation.get() == pending) connect(attempt = 0)
        }
    }

    private fun connectionEnded(ended: Int, attempt: Int, error: Exception?) {
        if (ended != generation.get() || !mutableState.value.isAttached) return
        if (!autoReconnect) {
            updateIfCurrent(ended) { state ->
                state.copy(isAttached = false, link = AgentLinkState.Detached, lastError = error?.userMessage ?: state.lastError)
            }
            return
        }
        // Con la vista abierta se reintenta solo, cada vez más espaciado.
        val next = attempt + 1
        updateIfCurrent(ended) { state ->
            state.copy(link = AgentLinkState.Reconnecting(next), lastError = error?.userMessage ?: state.lastError)
        }
        val wait = AgentReconnectPolicy.delaySeconds(next) * MILLIS_PER_SECOND
        retryJob = scope.launch {
            delay(wait)
            if (mutableState.value.isAttached && generation.get() == ended) connect(next)
        }
    }

    /**
     * Actualiza el estado solo si [current] sigue siendo el enganche vigente. La comprobación va
     * DENTRO del `update`: un `tail` viejo nunca escribe sobre la conversación nueva, aunque corra
     * en otro hilo (en Apple lo garantiza `@MainActor`).
     */
    private inline fun updateIfCurrent(
        current: Int,
        crossinline transform: (PersistentAgentSessionState) -> PersistentAgentSessionState,
    ) {
        mutableState.update { state -> if (generation.get() == current) transform(state) else state }
    }

    // MARK: Acciones

    /**
     * Envía un mensaje. El texto solo debe borrarse del campo con [AgentSendOutcome.SENT]. Si el
     * agente estaba hibernado, se reanuda solo (salvo en un modo que actúa sin preguntar, que pide
     * confirmación: ver [PersistentAgentMeta.resumeRequiresConfirmation]).
     */
    suspend fun send(rawText: String, oauthToken: suspend () -> String? = { null }, confirmedResume: Boolean = false): AgentSendOutcome {
        val text = SwiftText.trimWhitespaceAndNewlines(rawText)
        if (text.isEmpty()) return AgentSendOutcome.FAILED
        val before = mutableState.value
        if (!before.isAlive && (before.meta.isHibernated || confirmedResume)) {
            if (before.meta.resumeRequiresConfirmation && !confirmedResume) return AgentSendOutcome.NEEDS_RESUME_CONFIRMATION
            if (!resume(oauthToken())) return AgentSendOutcome.FAILED
        }
        val seenItems = mutableState.value.conversation.nextItemId
        val line = AgentProtocol.encodeUserMessage(text)
        var sent = write(line, answering = null)
        if (!sent && !mutableState.value.isAlive && refreshInfo() && mutableState.value.meta.isHibernated) {
            // Lo hibernó el vigilante mientras mirabas: se reanuda y se reintenta.
            if (mutableState.value.meta.resumeRequiresConfirmation && !confirmedResume) {
                return AgentSendOutcome.NEEDS_RESUME_CONFIRMATION
            }
            if (resume(oauthToken())) sent = write(line, answering = null)
        }
        if (!sent) return AgentSendOutcome.FAILED
        // Si el log ya trajo algo, manda él: el eco ya puso «trabajando» y un turno muy rápido
        // puede haber terminado ya, y no debe quedarse en «trabajando» para siempre.
        mutableState.update { state ->
            if (state.conversation.nextItemId != seenItems) return@update state
            state.copy(conversation = state.conversation.copy(status = AgentStatus.Working))
        }
        return AgentSendOutcome.SENT
    }

    /**
     * El permiso pendiente solo se retira si la respuesta LLEGÓ al agente (o si el agente ya no
     * está en marcha: no hay a quién responder).
     */
    suspend fun respond(request: AgentPermissionRequest, decision: AgentPermissionDecision) {
        val sent = write(AgentProtocol.encodePermissionResponse(request.id, decision), answering = request.id)
        if (!sent && mutableState.value.isAlive) return
        mutableState.update { state ->
            if (state.conversation.pendingPermission?.id != request.id) return@update state
            state.copy(conversation = state.conversation.copy(pendingPermission = null))
        }
    }

    suspend fun allowPendingPermission() {
        val request = mutableState.value.conversation.pendingPermission ?: return
        respond(request, AgentPermissionDecision.Allow(request.input))
    }

    suspend fun denyPendingPermission() {
        val request = mutableState.value.conversation.pendingPermission ?: return
        respond(request, AgentPermissionDecision.Deny(AgentPermissionDecision.USER_DENIED_MESSAGE))
    }

    /**
     * «Detener» el turno en curso: la petición de control `interrupt` por la FIFO (como en el
     * panel del Mac). El agente sigue vivo; el CLI cierra el turno con un `result`. Con un permiso
     * pendiente no se manda (se deniega desde su tarjeta y queda anotado para los demás
     * dispositivos). Devuelve si se envió.
     */
    suspend fun interrupt(): Boolean {
        val current = mutableState.value
        val canInterrupt = current.isAlive && current.conversation.status == AgentStatus.Working &&
            current.conversation.pendingPermission == null && !current.isInterrupting
        if (!canInterrupt) return false
        mutableState.update { it.copy(isInterrupting = true) }
        val requestID = "$INTERRUPT_REQUEST_PREFIX${UUID.randomUUID().toString().lowercase()}"
        val sent = write(AgentProtocol.encodeInterrupt(requestID), answering = null)
        if (!sent) mutableState.update { it.copy(isInterrupting = false) }
        return sent
    }

    /**
     * «Poner en reposo» a demanda: para el proceso SI en el servidor está quieto (su último evento
     * es un `result`); escribirle lo reanuda. Devuelve si lo hizo.
     */
    suspend fun hibernateNow(): Boolean = try {
        val output = service.runAgentScript(PersistentAgentScript.hibernate(id, minIdleSeconds = 0))
        val done = output.contains("${PersistentAgentScript.HIBERNATED_REPLY} $id")
        refreshInfo()
        when {
            done -> mutableState.update { it.copy(lastError = null) }
            mutableState.value.isAlive -> mutableState.update { it.copy(lastError = HIBERNATE_BUSY_MESSAGE) }
        }
        done
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Exception) {
        mutableState.update { it.copy(lastError = error.userMessage) }
        false
    }

    /**
     * Para el proceso del agente (la conversación se puede reanudar después). Con [delete], borra
     * también su log (solo si el proceso murió de verdad). Devuelve si se paró.
     */
    suspend fun stop(delete: Boolean = false): Boolean = try {
        service.runAgentScript(PersistentAgentScript.stop(id, delete))
        mutableState.update { it.copy(isAlive = false, isInterrupting = false) }
        if (delete) detach()
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Exception) {
        mutableState.update { it.copy(lastError = error.userMessage) }
        false
    }

    /** Relee del servidor si sigue vivo y su `meta.json` (p. ej. si se hibernó). */
    suspend fun refreshInfo(): Boolean = try {
        val info = list(service).firstOrNull { it.id == id }
        if (info != null) {
            listedLogBytes = info.logBytes
            mutableState.update { it.copy(meta = info.meta, isAlive = info.isAlive) }
        }
        info != null
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        false
    }

    /** Aplica un listado ajeno (sondeo de la vista) sin otro viaje al servidor. */
    fun adoptListed(info: PersistentAgentInfo) {
        if (info.id != id) return
        listedLogBytes = info.logBytes
        mutableState.update { it.copy(meta = info.meta, isAlive = info.isAlive) }
    }

    /** Devuelve si la línea llegó al agente. */
    private suspend fun write(line: String, answering: String?): Boolean = try {
        deliver(line, answering)
        mutableState.update { it.copy(lastError = null) }
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (dead: PersistentAgentException) {
        if (dead.error == PersistentAgentError.NOT_RUNNING) {
            val message = notRunningMessage()
            mutableState.update { it.copy(isAlive = false, lastError = message) }
        } else {
            mutableState.update { it.copy(lastError = dead.userMessage) }
        }
        false
    } catch (error: Exception) {
        mutableState.update { it.copy(lastError = error.userMessage) }
        false
    }

    /**
     * Las líneas pequeñas van dentro del comando; las grandes, por stdin (límite de 128 KiB por
     * argumento), con comprobación de que llegaron enteras.
     */
    private suspend fun deliver(line: String, answering: String?) {
        if (!PersistentAgentScript.needsStdin(line)) {
            service.runAgentScript(PersistentAgentScript.send(id, line, answering))
            return
        }
        val bytes = "$line\n".toByteArray(Charsets.UTF_8)
        val replies = setOf(
            PersistentAgentScript.SENT_REPLY, PersistentAgentScript.DEAD_REPLY,
            PersistentAgentScript.SHORT_REPLY, PersistentAgentScript.TIMEOUT_REPLY, PersistentAgentScript.BUSY_REPLY,
        )
        val reply = AgentStdinExchange.firstLine(
            exec,
            PersistentAgentScript.sendViaStdin(id, bytes.size, answering),
            bytes,
            timeoutMillis = (PersistentAgentScript.SEND_TIMEOUT_SECONDS + SEND_EXTRA_SECONDS) * MILLIS_PER_SECOND,
            accept = { it in replies },
        )
        when (reply) {
            PersistentAgentScript.SENT_REPLY -> Unit
            PersistentAgentScript.DEAD_REPLY -> throw PersistentAgentException(PersistentAgentError.NOT_RUNNING)
            PersistentAgentScript.SHORT_REPLY -> throw PersistentAgentException(PersistentAgentError.TRUNCATED_SEND)
            PersistentAgentScript.BUSY_REPLY -> throw PersistentAgentException(PersistentAgentError.BUSY)
            else -> throw AgentExchangeTimeoutException()
        }
    }

    /** «No está en marcha» + el final de `err.log` (por qué murió), si lo hay. */
    private suspend fun notRunningMessage(): String {
        val base = PersistentAgentError.NOT_RUNNING.message
        val tail = try {
            SwiftText.trimWhitespaceAndNewlines(service.runAgentScript(PersistentAgentScript.errorTail(id)))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            ""
        }
        return if (tail.isEmpty()) base else "$base\nÚltimo mensaje del servidor:\n${tail.takeLast(ERROR_TAIL_SHOWN)}"
    }

    companion object {
        private const val MILLIS_PER_SECOND = 1_000L
        private const val SEND_EXTRA_SECONDS = 30
        private const val LAUNCH_TIMEOUT_MILLIS = 60_000L
        private const val ERROR_TAIL_SHOWN = 600
        private const val LAUNCH_FAILED_MESSAGE = "No se pudo arrancar el agente en el servidor."

        /** Plazos entre comprobaciones del arranque ([watchStartup]): a los 2, 6 y 12 s. */
        val STARTUP_CHECKS_MILLIS: List<Long> = listOf(2_000L, 4_000L, 6_000L)

        /** Prefijo del `request_id` de las interrupciones (como Swift). */
        const val INTERRUPT_REQUEST_PREFIX = "argos-interrupt-"
        const val HIBERNATE_BUSY_MESSAGE =
            "Claude está trabajando o espera un permiso: no se puede poner en reposo ahora."

        /** Lanza un agente nuevo en [workingDirectory] y devuelve su sesión, aún sin enganchar. */
        suspend fun launch(
            service: SSHServicing,
            exec: AgentExecStreaming,
            workingDirectory: String,
            title: String,
            oauthToken: String?,
            scope: CoroutineScope,
            now: Instant = Instant.now(),
            permissionMode: ClaudeAgentCommand.PermissionMode = ClaudeAgentCommand.PermissionMode.DEFAULT,
            hibernation: PersistentAgentHibernation = PersistentAgentHibernation.STANDARD,
        ): PersistentAgentSession {
            val id = UUID.randomUUID().toString().lowercase()
            val meta = PersistentAgentMeta(workingDirectory, title, now, permissionMode.rawValue)
            val launched = start(service, exec, id, meta, resume = false, oauthToken = oauthToken, hibernation = hibernation)
            val session = PersistentAgentSession(service, exec, PersistentAgentInfo(id, true, 0, meta), scope, hibernation = { hibernation })
            if (launched) session.watchStartup()
            return session
        }

        suspend fun list(service: SSHServicing): List<PersistentAgentInfo> =
            PersistentAgentScript.parseList(service.runAgentScript(PersistentAgentScript.list()))

        private suspend fun start(
            service: SSHServicing,
            exec: AgentExecStreaming,
            id: String,
            meta: PersistentAgentMeta,
            resume: Boolean,
            oauthToken: String?,
            hibernation: PersistentAgentHibernation,
        ): Boolean {
            val claudePath = service.locateClaude() ?: throw PersistentAgentException(PersistentAgentError.CLAUDE_MISSING)
            val invocation = ClaudeAgentCommand.persistent(claudePath, id, resume, meta.resolvedPermissionMode)
            val command = PersistentAgentScript.launch(id, meta, invocation, hibernation)
            // El token va por stdin (primera línea), nunca en la línea de comandos.
            val reply = try {
                AgentStdinExchange.firstLine(
                    exec,
                    command,
                    ClaudeAgentCommand.tokenLine(oauthToken),
                    timeoutMillis = LAUNCH_TIMEOUT_MILLIS,
                    accept = PersistentAgentScript::isLaunchReply,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (timeout: AgentExchangeTimeoutException) {
                throw timeout
            } catch (failure: AgentExecException) {
                // Con detalle del servidor (stderr) se muestra; sin él, el mensaje del lanzador.
                throw if (failure.detail == AgentStdinExchange.NO_REPLY) AgentExecException(LAUNCH_FAILED_MESSAGE) else failure
            } catch (_: Exception) {
                throw AgentExecException(LAUNCH_FAILED_MESSAGE)
            }
            PersistentAgentScript.parseLaunchReply(reply)
            // `true` si lanzó un proceso nuevo (`false` si ya estaba vivo).
            return reply != PersistentAgentScript.ALIVE_REPLY
        }
    }
}
