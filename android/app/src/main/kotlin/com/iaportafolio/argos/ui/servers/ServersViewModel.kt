package com.iaportafolio.argos.ui.servers

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.AgentAttentionTracker
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.agent.AgentPermissionPreferences
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.data.TerminalSettingsStore
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Estado inmutable de la lista de servidores. */
data class ServersUiState(
    val servers: List<Server> = emptyList(),
    /** Servidor cuyo borrado espera confirmación (diálogo abierto). */
    val pendingDeletion: Server? = null,
    /** Aviso puntual (snackbar): resultado de una acción o error. */
    val message: UiText? = null,
    /** Modo de permisos por defecto de los agentes nuevos. */
    val agentPermissionMode: ClaudeAgentCommand.PermissionMode = AgentPermissionPreferences.FALLBACK,
    /** Avisos de agentes («terminó», «espera tu permiso»). */
    val agentNotificationsEnabled: Boolean = true,
    /** Mantener el terminal conectado en segundo plano. */
    val keepTerminalAlive: Boolean = true,
)

class ServersViewModel(
    private val repository: ServerRepository,
    private val secrets: SecretStore,
    private val hostKeys: HostKeyTrustStore,
    private val services: ServiceProvider,
    private val agentPermissions: AgentPermissionStore,
    private val io: CoroutineDispatcher,
    private val attention: AgentAttentionTracker,
    private val terminalSettings: TerminalSettingsStore,
) : ViewModel() {

    private val mutableState = MutableStateFlow(
        ServersUiState(
            servers = repository.servers.value,
            agentPermissionMode = agentPermissions.globalMode(),
            agentNotificationsEnabled = attention.notificationsEnabled.value,
            keepTerminalAlive = terminalSettings.settings.value.keepAliveInBackground,
        ),
    )
    val state: StateFlow<ServersUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            repository.servers.collect { servers -> mutableState.update { it.copy(servers = servers) } }
        }
        viewModelScope.launch {
            attention.notificationsEnabled.collect { enabled -> mutableState.update { it.copy(agentNotificationsEnabled = enabled) } }
        }
        viewModelScope.launch {
            terminalSettings.settings.collect { settings -> mutableState.update { it.copy(keepTerminalAlive = settings.keepAliveInBackground) } }
        }
    }

    fun requestDelete(server: Server) = mutableState.update { it.copy(pendingDeletion = server) }

    fun cancelDelete() = mutableState.update { it.copy(pendingDeletion = null) }

    fun confirmDelete() {
        val server = state.value.pendingDeletion ?: return
        mutableState.update { it.copy(pendingDeletion = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_STORE, "No se pudo borrar el servidor ${server.id}") {
                services.invalidate(server.id)
                withContext(io) {
                    repository.delete(server.id)
                    secrets.deleteAll(server.id)
                    attention.serverDeleted(server.id)
                    // La huella es por host:puerto: solo se olvida si ningún otro servidor lo usa.
                    if (repository.servers.value.none { it.endpoint == server.endpoint }) {
                        hostKeys.forget(server.endpoint)
                    }
                }
            }.onSuccess {
                ArgosLog.info(ArgosLog.TAG_STORE, "Servidor ${server.id} borrado")
            }.onFailure { error ->
                mutableState.update { it.copy(message = error.toUiText()) }
            }
        }
    }

    fun forgetHostKey(server: Server) {
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_HOST_KEY, "No se pudo olvidar la huella de ${server.endpoint}") {
                withContext(io) { hostKeys.forgetExplicitly(server.endpoint) }
                services.invalidate(server.id)
            }.onSuccess {
                mutableState.update { it.copy(message = UiText.res(R.string.host_key_forgotten, server.name)) }
            }.onFailure { error ->
                mutableState.update { it.copy(message = error.toUiText()) }
            }
        }
    }

    fun setAgentPermissionMode(mode: ClaudeAgentCommand.PermissionMode) {
        agentPermissions.setGlobalMode(mode)
        mutableState.update { it.copy(agentPermissionMode = mode) }
    }

    fun setAgentNotificationsEnabled(enabled: Boolean) = attention.setNotificationsEnabled(enabled)

    fun setKeepTerminalAlive(enabled: Boolean) = terminalSettings.setKeepAliveInBackground(enabled)

    fun messageShown() = mutableState.update { it.copy(message = null) }
}
