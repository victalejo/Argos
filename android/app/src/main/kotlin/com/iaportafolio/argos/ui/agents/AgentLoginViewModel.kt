package com.iaportafolio.argos.ui.agents

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.ClaudeLoginOutput
import com.iaportafolio.argos.core.agent.PersistentAgentError
import com.iaportafolio.argos.core.agent.PersistentAgentException
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Fases del login guiado (como `ClaudeSetupSheet` del Mac). */
sealed interface AgentLoginPhase {
    data object Starting : AgentLoginPhase

    data object Authorize : AgentLoginPhase

    data object Verifying : AgentLoginPhase

    /** [detail]: plan y correo que informó `claude auth status`. */
    data class Success(val detail: String?) : AgentLoginPhase

    data class Failed(val message: UiText) : AgentLoginPhase
}

data class AgentLoginUiState(
    val serverName: String = "",
    val phase: AgentLoginPhase = AgentLoginPhase.Starting,
    /** Solo de dominios de Anthropic ([ClaudeLoginOutput]): la salida viene del servidor. */
    val authorizationUrl: String? = null,
    val isAwaitingCode: Boolean = false,
) {
    val canSubmitCode: Boolean get() = isAwaitingCode && (phase == AgentLoginPhase.Authorize || phase is AgentLoginPhase.Failed)
}

sealed interface AgentLoginEvent {
    /** Sesión confirmada: se vuelve a la lista, que retoma la creación del agente. */
    data object Finished : AgentLoginEvent
}

data class AgentLoginPolicy(
    val verifyIntervalMillis: Long = 2_000,
    val verifyAttempts: Int = 30,
    /** Cuánto se ve la confirmación antes de cerrarse sola. */
    val successDisplayMillis: Long = 1_600,
)

/**
 * Login guiado de `claude auth login` (port de `ClaudeSetupSheet`). El comando corre en un PTY
 * del servidor ([com.iaportafolio.argos.ui.terminal.TerminalViewModel] con
 * `TerminalTarget.Command`); aquí se lee su salida y se convierte en pasos. El enlace solo se
 * abre tras confirmar en la pantalla; ni la salida ni el código se registran.
 */
class AgentLoginViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val policy: AgentLoginPolicy = AgentLoginPolicy(),
) : ViewModel() {

    private val mutableState = MutableStateFlow(AgentLoginUiState(serverName = repository.server(serverId)?.name.orEmpty()))
    val state: StateFlow<AgentLoginUiState> = mutableState.asStateFlow()

    private val eventChannel = Channel<AgentLoginEvent>(Channel.BUFFERED)
    val events: Flow<AgentLoginEvent> = eventChannel.receiveAsFlow()

    private val output = StringBuilder()
    private var verifyJob: Job? = null
    private var terminalStarted = false

    /** `true` solo la primera vez: la pantalla arranca el PTY una sola vez (no al rotar ni al volver). */
    fun claimTerminalStart(): Boolean = !terminalStarted.also { terminalStarted = true }

    /** Comando del PTY, con la ruta del binario (como `AgentPanelView.startLogin`). */
    suspend fun loginCommand(service: SSHServicing): String {
        val claude = service.locateClaude() ?: throw PersistentAgentException(PersistentAgentError.CLAUDE_MISSING)
        return "${ShellQuoting.singleQuoted(claude)} auth login --claudeai"
    }

    /** Salida del PTY, en orden. Acotada: el enlace y el prompt llegan al principio. */
    fun onTerminalOutput(chunks: List<ByteArray>) {
        chunks.forEach { output.append(String(it, Charsets.UTF_8)) }
        if (output.length > MAX_OUTPUT_CHARS) output.delete(0, output.length - MAX_OUTPUT_CHARS)
        val parsed = ClaudeLoginOutput.parse(output.toString())
        mutableState.update { state ->
            state.copy(
                authorizationUrl = parsed.authorizationURL?.toString() ?: state.authorizationUrl,
                isAwaitingCode = state.isAwaitingCode || parsed.isAwaitingCode,
                phase = if (state.phase == AgentLoginPhase.Starting && parsed.authorizationURL != null) AgentLoginPhase.Authorize else state.phase,
            )
        }
    }

    /**
     * Prepara el código pegado para teclearlo en el PTY y empieza a comprobar la sesión. `null`
     * si no toca o está vacío. Sin controles: un salto de línea interior no debe teclear nada.
     */
    fun submitCode(raw: String): ByteArray? {
        val code = raw.trim().filterNot { it.isISOControl() }
        if (code.isEmpty() || !state.value.canSubmitCode) return null
        verify()
        return "$code\r".toByteArray(Charsets.UTF_8)
    }

    /** El comando terminó o el PTY se cayó: si aún no consta la sesión, una última comprobación. */
    fun onTerminalEnded() {
        val phase = state.value.phase
        if (phase is AgentLoginPhase.Success || phase == AgentLoginPhase.Verifying) return
        verifyJob?.cancel()
        verifyJob = viewModelScope.launch {
            val status = authStatus()
            if (status?.loggedIn == true) {
                succeed(status)
            } else {
                mutableState.update { it.copy(phase = AgentLoginPhase.Failed(UiText.res(R.string.agents_login_ended))) }
            }
        }
    }

    /** «Empezar de nuevo»: la pantalla relanza el PTY; el enlace anterior ya no vale. */
    fun restart() {
        verifyJob?.cancel()
        output.clear()
        mutableState.update { it.copy(phase = AgentLoginPhase.Starting, authorizationUrl = null, isAwaitingCode = false) }
    }

    private fun verify() {
        verifyJob?.cancel()
        mutableState.update { it.copy(phase = AgentLoginPhase.Verifying) }
        verifyJob = viewModelScope.launch {
            repeat(policy.verifyAttempts) {
                delay(policy.verifyIntervalMillis)
                val status = authStatus()
                if (status?.loggedIn == true) {
                    succeed(status)
                    return@launch
                }
            }
            mutableState.update { it.copy(phase = AgentLoginPhase.Failed(UiText.res(R.string.agents_login_not_confirmed))) }
        }
    }

    private suspend fun succeed(status: ClaudeAuthStatus) {
        val detail = listOfNotNull(status.subscriptionType?.takeIf { it.isNotEmpty() }, status.email).joinToString(" · ")
        mutableState.update { it.copy(phase = AgentLoginPhase.Success(detail.ifEmpty { null })) }
        delay(policy.successDisplayMillis)
        eventChannel.send(AgentLoginEvent.Finished)
    }

    /** `null` si no se pudo comprobar: el sondeo sigue y el fallo final ya se muestra. */
    private suspend fun authStatus(): ClaudeAuthStatus? = agentFailures("No se pudo comprobar la sesión de Claude en $serverId") {
        val server = repository.server(serverId) ?: return@agentFailures null
        services.service(server).agentExec().claudeAuthStatus()
    }.getOrNull()

    private companion object {
        const val MAX_OUTPUT_CHARS = 20_000
    }
}
