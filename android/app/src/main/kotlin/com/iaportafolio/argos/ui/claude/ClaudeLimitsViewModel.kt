package com.iaportafolio.argos.ui.claude

import androidx.annotation.StringRes
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.ConnectionPriority
import com.iaportafolio.argos.core.usage.ClaudeLimitsAccess
import com.iaportafolio.argos.core.usage.ClaudeLimitsStatus
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.files.FileServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant

/** ¿Está puesta la statusline de Argos que lee los límites? */
sealed interface ClaudeLimitsSetup {
    data object Checking : ClaudeLimitsSetup
    data object Inactive : ClaudeLimitsSetup
    data object Active : ClaudeLimitsSetup
    data class Failed(val message: String) : ClaudeLimitsSetup
}

data class ClaudeLimitsUiState(
    val serverName: String = "",
    val setup: ClaudeLimitsSetup = ClaudeLimitsSetup.Checking,
    val isWorking: Boolean = false,
    /** Resultado de la última acción, bajo los botones. */
    val notice: UiText? = null,
    /** Últimos límites leídos (`null` = sin datos aún). */
    val status: ClaudeLimitsStatus? = null,
)

/**
 * «Límites de Claude» de un servidor (port de `ClaudeLimitsSetupModel.swift` y de
 * `ClaudeLimitsScreen` de iOS): activar o quitar la statusline de Argos y ver los medidores.
 */
class ClaudeLimitsViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
    private val clock: () -> Instant = Instant::now,
) : ViewModel() {

    private val mutableState = MutableStateFlow(ClaudeLimitsUiState(serverName = repository.server(serverId)?.name.orEmpty()))
    val state: StateFlow<ClaudeLimitsUiState> = mutableState.asStateFlow()

    /** Comprueba si está activa y relee los límites (al abrir la pantalla y en «Reintentar»). */
    fun refresh() {
        viewModelScope.launch { refreshNow() }
    }

    suspend fun refreshNow() {
        logFailures(ArgosLog.TAG_SSH, "No se pudo comprobar la statusline de límites de $serverId") {
            withContext(io) { access().claudeLimitsInstalled() }
        }.onSuccess { installed ->
            mutableState.update { it.copy(setup = if (installed) ClaudeLimitsSetup.Active else ClaudeLimitsSetup.Inactive) }
            if (installed) readLimits()
        }.onFailure { error -> mutableState.update { it.copy(setup = ClaudeLimitsSetup.Failed(error.userMessage)) } }
    }

    fun activate() = perform(R.string.claude_limits_activate_failed) {
        access().installClaudeLimits()
        mutableState.update { it.copy(setup = ClaudeLimitsSetup.Active, notice = UiText.res(R.string.claude_limits_activated)) }
    }

    fun deactivate() = perform(R.string.claude_limits_remove_failed) {
        access().uninstallClaudeLimits()
        mutableState.update {
            it.copy(setup = ClaudeLimitsSetup.Inactive, status = null, notice = UiText.res(R.string.claude_limits_removed))
        }
    }

    /** Informativo: un fallo conserva la última lectura. */
    private suspend fun readLimits() {
        logFailures(ArgosLog.TAG_SSH, "No se pudieron leer los límites de Claude de $serverId") {
            ConnectionPriority.background { withContext(io) { access().claudeLimits() } }
        }.onSuccess { reading ->
            mutableState.update { it.copy(status = reading?.let { r -> ClaudeLimitsStatus.evaluate(r, clock()) }) }
        }
    }

    private fun perform(@StringRes failure: Int, action: suspend () -> Unit) {
        if (state.value.isWorking) return
        mutableState.update { it.copy(isWorking = true, notice = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "Statusline de límites de $serverId") { withContext(io) { action() } }
                .onFailure { error -> mutableState.update { it.copy(notice = UiText.res(failure, error.userMessage)) } }
            mutableState.update { it.copy(isWorking = false) }
        }
    }

    private suspend fun access(): ClaudeLimitsAccess {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.service(server) as? ClaudeLimitsAccess ?: throw UnsupportedOperationException(UNSUPPORTED)
    }

    private companion object {
        const val UNSUPPORTED = "Esta conexión no admite los límites de Claude. Actualiza Argos."
    }
}
