package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.receiveAsFlow
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
    val isAttached: Boolean = false,
    /** Bytes del log leídos en este enganche: lo que el usuario ya ha visto. */
    val receivedBytes: Long = 0,
    val lastError: String? = null,
)

/**
 * Cliente de un agente persistente (port de `PersistentAgentSession.swift`). El agente corre
 * en el servidor; esta clase solo se ENGANCHA a su log para pintar la conversación y le escribe
 * por la FIFO. Desengancharse (segundo plano, cerrar la vista, perder la red) no para al
 * agente; volver a engancharse relee el log y reconstruye todo.
 *
 * [scope] es del dueño (p. ej. `viewModelScope`): al cancelarlo se desengancha.
 */
class PersistentAgentSession(
    private val service: SSHServicing,
    private val exec: AgentExecStreaming,
    info: PersistentAgentInfo,
    private val scope: CoroutineScope,
) {
    val id: String = info.id

    private val mutableState = MutableStateFlow(PersistentAgentSessionState(meta = info.meta, isAlive = info.isAlive))
    val state: StateFlow<PersistentAgentSessionState> = mutableState.asStateFlow()

    /** Un `tail` viejo que termina tarde no debe tocar el estado del enganche actual. */
    private val generation = AtomicInteger(0)

    @Volatile
    private var job: Job? = null

    /** Relanza el proceso con `--resume` (p. ej. tras reiniciarse el servidor) y se reengancha. */
    suspend fun resume(oauthToken: String?) {
        runReportingErrors {
            start(service, exec, id, mutableState.value.meta, resume = true, oauthToken = oauthToken)
            mutableState.update { it.copy(isAlive = true, lastError = null) }
            attach()
        }
    }

    /** (Re)engancha: vacía la conversación y relee el log desde el principio. */
    fun attach() {
        detach()
        val current = generation.incrementAndGet()
        mutableState.update {
            it.copy(conversation = AgentConversationState(), receivedBytes = 0, isAttached = true)
        }
        job = scope.launch {
            var buffer = NdjsonLineBuffer()
            try {
                // stdin que no termina nunca: si acabara, `runAgentExec` terminaría también.
                val keepOpen = flow<ByteArray> { awaitCancellation() }
                exec.runAgentExec(PersistentAgentScript.attach(id), keepOpen) { chunk ->
                    if (generation.get() == current) {
                        val appended = buffer.append(chunk)
                        buffer = appended.buffer
                        applyLines(current, chunk.size, appended.lines)
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                updateIfCurrent(current) { it.copy(lastError = error.userMessage) }
            } finally {
                updateIfCurrent(current) { it.copy(isAttached = false) }
            }
        }
    }

    /** Deja de leer el log. El agente sigue trabajando en el servidor. */
    fun detach() {
        generation.incrementAndGet()
        job?.cancel()
        job = null
        mutableState.update { it.copy(isAttached = false) }
    }

    /** Envía un mensaje del usuario (la burbuja llega por el eco del log). */
    suspend fun send(rawText: String) {
        val text = SwiftText.trimWhitespaceAndNewlines(rawText)
        if (text.isEmpty()) return
        val seenItems = mutableState.value.conversation.nextItemId
        val delivered = write(AgentProtocol.encodeUserMessage(text), answering = null)
        if (delivered) {
            // Si el log ya trajo algo, manda él: el eco ya puso «trabajando» y un turno muy rápido
            // puede haber terminado ya, y no debe quedarse en «trabajando» para siempre.
            mutableState.update { state ->
                if (state.conversation.nextItemId != seenItems) return@update state
                state.copy(conversation = state.conversation.copy(status = AgentStatus.Working))
            }
        }
    }

    suspend fun respond(request: AgentPermissionRequest, decision: AgentPermissionDecision) {
        // Si no llegó, el agente sigue esperando: la tarjeta debe seguir a la vista.
        if (!write(AgentProtocol.encodePermissionResponse(request.id, decision), answering = request.id)) return
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

    /** Para el proceso (la conversación se puede reanudar). Con [delete], borra también su log. */
    suspend fun stop(delete: Boolean = false) {
        runReportingErrors {
            service.runAgentScript(PersistentAgentScript.stop(id, delete))
            mutableState.update { it.copy(isAlive = false) }
            if (delete) detach()
        }
    }

    private fun applyLines(current: Int, bytes: Int, lines: List<String>) {
        updateIfCurrent(current) { state ->
            val conversation = lines.fold(state.conversation) { acc, line ->
                AgentProtocol.decode(line)?.let { AgentReducer.apply(it, acc, echoesUserMessages = true) } ?: acc
            }
            state.copy(conversation = conversation, receivedBytes = state.receivedBytes + bytes, lastError = null)
        }
    }

    /**
     * Actualiza el estado solo si [current] sigue siendo el enganche vigente. La comprobación va
     * DENTRO del `update`: como `attach` cambia la generación antes de vaciar el estado, un `tail`
     * viejo nunca escribe sobre la conversación nueva, aunque corra en otro hilo (en Apple lo
     * garantiza `@MainActor`).
     */
    private inline fun updateIfCurrent(
        current: Int,
        crossinline transform: (PersistentAgentSessionState) -> PersistentAgentSessionState,
    ) {
        mutableState.update { state -> if (generation.get() == current) transform(state) else state }
    }

    /** Devuelve si la línea llegó a la FIFO. */
    private suspend fun write(line: String, answering: String?): Boolean = try {
        service.runAgentScript(PersistentAgentScript.send(id, line, answering))
        mutableState.update { it.copy(lastError = null) }
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (dead: PersistentAgentException) {
        // Como en Swift: solo NOT_RUNNING marca muerto; el resto es un error sin más.
        mutableState.update { state ->
            val isAlive = if (dead.error == PersistentAgentError.NOT_RUNNING) false else state.isAlive
            state.copy(isAlive = isAlive, lastError = dead.userMessage)
        }
        false
    } catch (error: Exception) {
        mutableState.update { it.copy(lastError = error.userMessage) }
        false
    }

    private suspend fun runReportingErrors(block: suspend () -> Unit) {
        try {
            block()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            mutableState.update { it.copy(lastError = error.userMessage) }
        }
    }

    companion object {
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
        ): PersistentAgentSession {
            val id = UUID.randomUUID().toString().lowercase()
            val meta = PersistentAgentMeta(workingDirectory, title, now, permissionMode.rawValue)
            start(service, exec, id, meta, resume = false, oauthToken = oauthToken)
            return PersistentAgentSession(service, exec, PersistentAgentInfo(id, true, 0, meta), scope)
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
        ) {
            val claudePath = service.locateClaude() ?: throw PersistentAgentException(PersistentAgentError.CLAUDE_MISSING)
            val invocation = ClaudeAgentCommand.persistent(claudePath, id, resume, meta.resolvedPermissionMode)
            val command = PersistentAgentScript.launch(id, meta, invocation)

            // El token va por stdin (primera línea), nunca en la línea de comandos. stdin se
            // cierra en cuanto el lanzador responde (PID o «ya vivo»).
            val input = Channel<ByteArray>(Channel.UNLIMITED)
            input.trySend(ClaudeAgentCommand.tokenLine(oauthToken))
            val reply = StringBuilder()
            // Como el `try?` de Swift: manda lo que respondió el lanzador, no su código de salida
            // (`ARGOS_AGENT_BUSY` sale con 4 y cerrar stdin puede cortar el canal a medias).
            val failure = try {
                exec.runAgentExec(command, input.receiveAsFlow()) { chunk ->
                    reply.append(String(chunk))
                    if ('\n' in reply) input.close()
                }
                null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                error
            }
            input.close()
            when (PersistentAgentScript.parseLaunchReply(reply.toString())) {
                PersistentAgentLaunchReply.RUNNING -> Unit
                PersistentAgentLaunchReply.BUSY -> throw PersistentAgentException(PersistentAgentError.BUSY)
                PersistentAgentLaunchReply.FAILED ->
                    throw failure as? AgentExecException ?: AgentExecException("No se pudo arrancar el agente en el servidor.")
            }
        }
    }
}
