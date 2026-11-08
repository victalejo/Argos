package com.iaportafolio.argos.ui.servers

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
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
)

class ServersViewModel(
    private val repository: ServerRepository,
    private val secrets: SecretStore,
    private val hostKeys: HostKeyTrustStore,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(ServersUiState(servers = repository.servers.value))
    val state: StateFlow<ServersUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            repository.servers.collect { servers -> mutableState.update { it.copy(servers = servers) } }
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
                withContext(io) { hostKeys.forget(server.endpoint) }
                services.invalidate(server.id)
            }.onSuccess {
                mutableState.update { it.copy(message = UiText.res(R.string.host_key_forgotten, server.name)) }
            }.onFailure { error ->
                mutableState.update { it.copy(message = error.toUiText()) }
            }
        }
    }

    fun messageShown() = mutableState.update { it.copy(message = null) }
}
