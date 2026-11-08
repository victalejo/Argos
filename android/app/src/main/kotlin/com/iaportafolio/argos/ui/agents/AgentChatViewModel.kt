package com.iaportafolio.argos.ui.agents

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.agent.AgentPermissionDecision
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.core.agent.PersistentAgentSession
import com.iaportafolio.argos.core.agent.PersistentAgentSessionState
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ClaudeTokenStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.ReconnectPolicy
import com.iaportafolio.argos.ui.terminal.TerminalServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Tiempos del chat. Los de reintento son los del terminal. */
data class AgentChatPolicy(
    val reconnect: ReconnectPolicy = ReconnectPolicy(),
    /** Cada cuánto se comprueba si el proceso sigue vivo: `tail -F` no termina cuando muere. */
    val livenessIntervalMillis: Long = 15_000,
    /** Tope para retener la conversación anterior mientras se relee el log (ver [ReplayHold]). */
    val replayTimeoutMillis: Long = 10_000,
)

/**
 * Conversación con un agente persistente (port de `AgentChatView` de iOS). El agente corre en
 * el servidor: [onStart] se engancha a su log y lo sigue reenganchando con backoff si se cae;
 * [onStop] se desengancha y el agente continúa. Nunca entra en el estado el token ni se registra
 * contenido de la conversación.
 */
class AgentChatViewModel(
    private val serverId: String,
    private val agentId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val tokens: ClaudeTokenStore,
    private val io: CoroutineDispatcher,
    private val policy: AgentChatPolicy = AgentChatPolicy(),
) : ViewModel() {

    private val mutableState = MutableStateFlow(AgentChatUiState())
    val state: StateFlow<AgentChatUiState> = mutableState.asStateFlow()

    private val eventChannel = Channel<AgentChatEvent>(Channel.BUFFERED)
    val events: Flow<AgentChatEvent> = eventChannel.receiveAsFlow()

    private var session: PersistentAgentSession? = null
    private var service: SSHServicing? = null
    private var superviseJob: Job? = null
    private var inForeground = false

    /** Mayor tamaño de log conocido: hasta ahí llega lo que el usuario ya ha visto. */
    private var knownLogBytes = 0L
    private val replayTarget = MutableStateFlow(0L)

    /** Último `isAlive` de la sesión: el sondeo también lo actualiza, gana el último cambio. */
    private var lastSessionAlive: Boolean? = null

    @Volatile
    private var redactor = SecretRedactor()

    // MARK: - Ciclo de vida

    /** Primer plano (ON_START): engancha si no hay ya un enganche en marcha. */
    fun onStart() {
        inForeground = true
        if (superviseJob?.isActive == true || state.value.load == AgentChatLoad.Missing) return
        startSupervisor()
    }

    /** Segundo plano o salir (ON_STOP): deja de leer el log. El agente sigue en el servidor. */
    fun onStop() {
        inForeground = false
        superviseJob?.cancel()
        superviseJob = null
        session?.detach()
    }

    /** «Reconectar» / «Reintentar»: enganche nuevo con la cuenta de reintentos a cero. */
    fun reconnect() {
        if (state.value.load is AgentChatLoad.Failed) mutableState.update { it.copy(load = AgentChatLoad.Loading) }
        startSupervisor()
    }

    private fun startSupervisor() {
        val previous = superviseJob
        previous?.cancel()
        superviseJob = viewModelScope.launch {
            previous?.cancelAndJoin()
            val current = ensureSession() ?: return@launch
            coroutineScope {
                val liveness = launch { pollLiveness(current) }
                attachLoop(current)
                liveness.cancel()
            }
        }
    }

    private suspend fun ensureSession(): PersistentAgentSession? {
        session?.let { return it }
        val result = agentFailures("No se pudo abrir el agente $agentId") {
            val server = repository.server(serverId) ?: throw TerminalServerMissingException()
            val ssh = services.service(server)
            val exec = ssh.agentExec()
            redactor = SecretRedactor(readTokenForRedaction())
            val info = withContext(io) { PersistentAgentSession.list(ssh) }.firstOrNull { it.id == agentId }
            info?.let { Triple(ssh, exec, it) }
        }
        return result.fold(
            onSuccess = { found ->
                if (found == null) {
                    mutableState.update { it.copy(load = AgentChatLoad.Missing) }
                    null
                } else {
                    val (ssh, exec, info) = found
                    service = ssh
                    knownLogBytes = info.logBytes
                    mutableState.update {
                        it.copy(
                            load = AgentChatLoad.Ready,
                            title = info.meta.title,
                            workingDirectory = info.meta.workingDirectory,
                            permissionMode = info.meta.resolvedPermissionMode,
                            isAlive = info.isAlive,
                        )
                    }
                    // Un scope propio solo cambia de hilo: decodificar un log largo no bloquea la UI.
                    PersistentAgentSession(ssh, exec, info, CoroutineScope(viewModelScope.coroutineContext + io)).also {
                        session = it
                        collectSession(it)
                    }
                }
            },
            onFailure = { error ->
                mutableState.update { it.copy(load = AgentChatLoad.Failed(error.toAgentUiText(redactor))) }
                null
            },
        )
    }

    /** Sin el token no se puede tapar el exacto, pero sigue tapándose lo que tenga su forma. */
    private suspend fun readTokenForRedaction(): String? =
        agentFailures("No se pudo leer el token de Claude") { withContext(io) { tokens.read() } }.getOrNull()

    private fun collectSession(current: PersistentAgentSession) {
        val projector = TranscriptProjector { redactor }
        val hold = ReplayHold()
        viewModelScope.launch {
            combine(current.state, replayTarget) { session, target ->
                val replaying = hold.isReplaying(session.receivedBytes, target)
                Projection(
                    session = session,
                    rows = hold.rowsToShow(projector.project(session.conversation.items), replaying),
                    permission = session.conversation.pendingPermission?.let { AgentTranscriptPresenter.permissionCard(it, redactor) },
                    replaying = replaying,
                )
            }.flowOn(io).collect(::applyProjection)
        }
    }

    private class Projection(
        val session: PersistentAgentSessionState,
        val rows: List<AgentTranscriptRow>,
        val permission: AgentPermissionCard?,
        val replaying: Boolean,
    )

    private fun applyProjection(projection: Projection) {
        val alive = projection.session.isAlive
        val aliveChanged = alive != lastSessionAlive
        lastSessionAlive = alive
        mutableState.update {
            it.copy(
                rows = projection.rows,
                conversationStatus = projection.session.conversation.status,
                permission = projection.permission,
                isReplaying = projection.replaying,
                isAlive = if (aliveChanged) alive else it.isAlive,
            )
        }
    }

    // MARK: - Enganche con backoff

    private suspend fun attachLoop(current: PersistentAgentSession) = coroutineScope {
        var attempt = 0
        while (true) {
            mutableState.update {
                it.copy(connection = if (attempt == 0) AgentConnection.Connecting else AgentConnection.Retrying(attempt, null))
            }
            knownLogBytes = maxOf(knownLogBytes, current.state.value.receivedBytes)
            replayTarget.value = knownLogBytes
            current.attach()
            val replayTimer = launch {
                delay(policy.replayTimeoutMillis)
                replayTarget.value = 0
            }
            val firstSignal = current.state.first { !it.isAttached || it.receivedBytes > 0 }
            if (firstSignal.isAttached) {
                attempt = 0
                mutableState.update { it.copy(connection = AgentConnection.Connected) }
            }
            val fell = current.state.first { !it.isAttached }
            replayTimer.cancel()
            knownLogBytes = maxOf(knownLogBytes, fell.receivedBytes)
            ArgosLog.warn(ArgosLog.TAG_AGENT, "Enganche del agente $agentId caído (intento $attempt)")

            if (attempt >= policy.reconnect.maxAttempts) {
                val message = fell.lastError?.let { UiText.Plain(redactor.redact(it)) } ?: UiText.res(R.string.agents_chat_connection_lost)
                mutableState.update { it.copy(connection = AgentConnection.Lost(message)) }
                return@coroutineScope
            }
            val wait = policy.reconnect.delayFor(attempt)
            attempt++
            val seconds = ((wait + MILLIS_PER_SECOND - 1) / MILLIS_PER_SECOND).toInt()
            mutableState.update { it.copy(connection = AgentConnection.Retrying(attempt, seconds)) }
            delay(wait)
        }
    }

    /** Detecta que el proceso murió (o que lo reanudó o borró otro dispositivo). */
    private suspend fun pollLiveness(current: PersistentAgentSession) {
        val ssh = service ?: return
        while (true) {
            agentFailures("No se pudo comprobar el agente $agentId") {
                withContext(io) { PersistentAgentSession.list(ssh) }
            }.onSuccess { agents ->
                val info = agents.firstOrNull { it.id == agentId }
                if (info == null) {
                    agentDisappeared(current)
                    return
                }
                mutableState.update {
                    // El canal SSH responde y el enganche sigue abierto: un log vacío no da otra señal.
                    val reachable = current.state.value.isAttached && it.connection !is AgentConnection.Lost
                    it.copy(isAlive = info.isAlive, connection = if (reachable) AgentConnection.Connected else it.connection)
                }
            }
            delay(policy.livenessIntervalMillis)
        }
    }

    private fun agentDisappeared(current: PersistentAgentSession) {
        superviseJob?.cancel()
        superviseJob = null
        current.detach()
        mutableState.update { it.copy(load = AgentChatLoad.Missing) }
    }

    // MARK: - Mensajes

    /** Envía [rawText]. La burbuja llega por el eco del log; si falla, el texto se conserva. */
    fun send(rawText: String) {
        val current = session ?: return
        if (rawText.isBlank() || !state.value.canSend) return
        mutableState.update { it.copy(isSending = true) }
        viewModelScope.launch {
            try {
                current.send(rawText)
                val failure = current.state.value.lastError
                if (failure == null) {
                    mutableState.update { it.copy(error = null) }
                    eventChannel.send(AgentChatEvent.MessageSent)
                } else {
                    ArgosLog.warn(ArgosLog.TAG_AGENT, "No se pudo enviar al agente $agentId")
                    mutableState.update { it.copy(error = UiText.Plain(redactor.redact(failure))) }
                }
            } finally {
                mutableState.update { it.copy(isSending = false) }
            }
        }
    }

    // MARK: - Permisos

    /**
     * Responde a la petición [requestId], la que el usuario tiene delante. Si entretanto cambió
     * no se hace nada: nunca se aprueba una petición que no se ha visto.
     */
    fun decidePermission(requestId: String, allow: Boolean) {
        val current = session ?: return
        val request = current.state.value.conversation.pendingPermission?.takeIf { it.id == requestId } ?: return
        if (!state.value.canDecidePermission || state.value.visiblePermission?.requestId != requestId) return
        mutableState.update { it.copy(isResponding = true) }
        viewModelScope.launch {
            try {
                val decision = if (allow) {
                    AgentPermissionDecision.Allow(request.input)
                } else {
                    AgentPermissionDecision.Deny(AgentPermissionDecision.USER_DENIED_MESSAGE)
                }
                current.respond(request, decision)
                val failure = current.state.value.lastError
                if (failure == null) {
                    mutableState.update { it.copy(error = null) }
                } else {
                    ArgosLog.warn(ArgosLog.TAG_AGENT, "No se pudo responder al permiso del agente $agentId")
                    mutableState.update { it.copy(error = UiText.Plain(redactor.redact(failure))) }
                }
            } finally {
                mutableState.update { it.copy(isResponding = false) }
            }
        }
    }

    // MARK: - Parar, reanudar, borrar

    fun stop() {
        val current = session ?: return
        if (state.value.isStopping) return
        mutableState.update { it.copy(isStopping = true) }
        viewModelScope.launch {
            try {
                current.stop()
                val after = current.state.value
                if (after.isAlive) {
                    // stop() informa los fallos solo por `lastError`; si el proceso sigue vivo, falló.
                    ArgosLog.warn(ArgosLog.TAG_AGENT, "No se pudo parar el agente $agentId")
                    val message = after.lastError?.let { UiText.Plain(redactor.redact(it)) } ?: UiText.res(R.string.agents_stop_failed)
                    mutableState.update { it.copy(error = message) }
                } else {
                    mutableState.update { it.copy(isAlive = false, error = null) }
                }
            } finally {
                mutableState.update { it.copy(isStopping = false) }
            }
        }
    }

    /**
     * Pide reanudar. `meta.json` puede haberlo editado el propio agente, así que los modos que
     * actúan sin preguntar exigen que el usuario los confirme ([confirmResume]).
     */
    fun resume() {
        val current = session ?: return
        if (state.value.isResuming) return
        val meta = current.state.value.meta
        if (meta.resumeRequiresConfirmation) {
            mutableState.update { it.copy(confirmResumeMode = meta.resolvedPermissionMode) }
        } else {
            performResume(current)
        }
    }

    fun cancelResume() = mutableState.update { it.copy(confirmResumeMode = null) }

    fun confirmResume() {
        val current = session ?: return
        if (state.value.confirmResumeMode == null || state.value.isResuming) return
        performResume(current)
    }

    /** Relanza el proceso con `--resume`. El token solo viaja por stdin. */
    private fun performResume(current: PersistentAgentSession) {
        mutableState.update { it.copy(isResuming = true, confirmResumeMode = null) }
        viewModelScope.launch {
            try {
                superviseJob?.cancelAndJoin()
                knownLogBytes = maxOf(knownLogBytes, current.state.value.receivedBytes)
                agentFailures("No se pudo leer el token para reanudar $agentId") {
                    withContext(io) { tokens.read() }
                }.onSuccess { token ->
                    if (token != null) redactor = SecretRedactor(token)
                    current.resume(token)
                    val failure = current.state.value.lastError
                    if (failure == null) {
                        mutableState.update { it.copy(isAlive = true, error = null) }
                    } else {
                        ArgosLog.warn(ArgosLog.TAG_AGENT, "No se pudo reanudar el agente $agentId")
                        mutableState.update { it.copy(error = UiText.Plain(redactor.redact(failure))) }
                    }
                }.onFailure { error ->
                    mutableState.update { it.copy(error = error.toAgentUiText(redactor)) }
                }
            } finally {
                mutableState.update { it.copy(isResuming = false) }
            }
            if (inForeground) startSupervisor() else current.detach()
        }
    }

    fun requestDelete() = mutableState.update { it.copy(confirmDelete = true) }

    fun cancelDelete() = mutableState.update { it.copy(confirmDelete = false) }

    /** Para el proceso y borra su carpeta del servidor. Si falla, la conversación sigue abierta. */
    fun confirmDelete() {
        val current = session ?: return
        val ssh = service ?: return
        if (state.value.isDeleting) return
        mutableState.update { it.copy(confirmDelete = false, isDeleting = true) }
        viewModelScope.launch {
            agentFailures("No se pudo borrar el agente $agentId") {
                withContext(io) { ssh.runAgentScript(PersistentAgentScript.stop(agentId, delete = true)) }
            }.onSuccess {
                superviseJob?.cancel()
                superviseJob = null
                current.detach()
                eventChannel.send(AgentChatEvent.Closed)
            }.onFailure { error ->
                mutableState.update { it.copy(error = error.toAgentUiText(redactor)) }
            }
            mutableState.update { it.copy(isDeleting = false) }
        }
    }

    fun errorDismissed() = mutableState.update { it.copy(error = null) }

    private companion object {
        const val MILLIS_PER_SECOND = 1_000L
    }
}
