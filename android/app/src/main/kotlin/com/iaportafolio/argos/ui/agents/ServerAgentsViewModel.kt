package com.iaportafolio.argos.ui.agents

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.agent.PersistentAgentHibernation
import com.iaportafolio.argos.core.agent.ServerAgentActions
import com.iaportafolio.argos.core.agent.ServerAgentInventory
import com.iaportafolio.argos.core.agent.ServerAgentProcess
import com.iaportafolio.argos.core.agent.serverAgentInventory
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.TerminalServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

sealed interface ServerAgentsLoad {
    data object Loading : ServerAgentsLoad

    data class Failed(val message: UiText) : ServerAgentsLoad

    data class Loaded(val inventory: ServerAgentInventory) : ServerAgentsLoad
}

data class ServerAgentsUiState(
    val serverName: String = "",
    val load: ServerAgentsLoad = ServerAgentsLoad.Loading,
    val isRefreshing: Boolean = false,
    /** Hay una acción (parar, hibernar) en curso. */
    val isWorking: Boolean = false,
    val confirmStopAll: Boolean = false,
    /** Plazo de reposo de este dispositivo: decide qué cuenta como «inactivo». */
    val hibernation: PersistentAgentHibernation = PersistentAgentHibernation.STANDARD,
    /** Fallo de la última acción: no lo borra el refresco posterior. */
    val actionError: UiText? = null,
) {
    val inventory: ServerAgentInventory? get() = (load as? ServerAgentsLoad.Loaded)?.inventory

    val candidates: List<ServerAgentProcess>
        get() = if (hibernation.isEnabled) inventory?.hibernationCandidates(hibernation.idleSeconds.toLong()).orEmpty() else emptyList()
}

/**
 * «Agentes en este servidor» (port de `ServerAgentsView` de iOS): TODOS los agentes de Argos del
 * servidor, de cualquier proyecto (persistentes y conversaciones del panel del Mac), con su
 * memoria e inactividad. Detener uno, detener todos (cada uno en su subshell: los atascados se
 * dicen) e hibernar los inactivos (el servidor vuelve a comprobar que siguen quietos).
 */
class ServerAgentsViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val settings: AgentPermissionStore,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(
        ServerAgentsUiState(serverName = repository.server(serverId)?.name.orEmpty(), hibernation = settings.hibernation()),
    )
    val state: StateFlow<ServerAgentsUiState> = mutableState.asStateFlow()

    private var loadJob: Job? = null
    private val redactor = SecretRedactor()

    init {
        refresh()
    }

    fun refresh() {
        loadJob?.cancel()
        mutableState.update {
            val refreshing = it.load is ServerAgentsLoad.Loaded
            it.copy(isRefreshing = refreshing, load = if (refreshing) it.load else ServerAgentsLoad.Loading, hibernation = settings.hibernation())
        }
        loadJob = viewModelScope.launch { load() }
    }

    private suspend fun load() {
        agentFailures("No se pudo leer el inventario de agentes de $serverId") {
            withContext(io) { service().serverAgentInventory() }
        }.onSuccess { inventory ->
            mutableState.update { it.copy(load = ServerAgentsLoad.Loaded(inventory)) }
        }.onFailure { error ->
            mutableState.update { state ->
                if (state.load is ServerAgentsLoad.Loaded) {
                    state.copy(actionError = error.toAgentUiText(redactor))
                } else {
                    state.copy(load = ServerAgentsLoad.Failed(error.toAgentUiText(redactor)))
                }
            }
        }
        mutableState.update { it.copy(isRefreshing = false) }
    }

    fun stop(agent: ServerAgentProcess) = perform(stopAgents(listOf(agent)))

    fun requestStopAll() = mutableState.update { it.copy(confirmStopAll = true) }

    fun cancelStopAll() = mutableState.update { it.copy(confirmStopAll = false) }

    fun confirmStopAll() {
        mutableState.update { it.copy(confirmStopAll = false) }
        val live = state.value.inventory?.liveAgents.orEmpty()
        perform(stopAgents(live))
    }

    fun hibernateIdle() {
        val candidates = state.value.candidates
        val minimum = state.value.hibernation.idleSeconds
        if (candidates.isEmpty()) return
        perform { ssh -> ServerAgentActions.hibernate(candidates, minimum, ssh) }
    }

    fun actionErrorShown() = mutableState.update { it.copy(actionError = null) }

    private fun stopAgents(agents: List<ServerAgentProcess>): suspend (SSHServicing) -> List<String> =
        { ssh -> ServerAgentActions.stop(agents, ssh) }

    /** Ejecuta una acción que devuelve los agentes que no pudo tratar (p. ej. atascados). */
    private fun perform(action: suspend (SSHServicing) -> List<String>) {
        if (state.value.isWorking) return
        mutableState.update { it.copy(isWorking = true) }
        viewModelScope.launch {
            agentFailures("Acción sobre los agentes de $serverId fallida") {
                withContext(io) { action(service()) }
            }.onSuccess { failed ->
                ServerAgentActions.failedNames(failed, state.value.inventory)?.let { names ->
                    mutableState.update { it.copy(actionError = UiText.res(R.string.server_agents_failed, names)) }
                }
            }.onFailure { error ->
                mutableState.update { it.copy(actionError = error.toAgentUiText(redactor)) }
            }
            load()
            mutableState.update { it.copy(isWorking = false) }
        }
    }

    private suspend fun service(): SSHServicing {
        val server = repository.server(serverId) ?: throw TerminalServerMissingException()
        return services.service(server)
    }
}
