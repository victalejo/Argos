package com.iaportafolio.argos.ui.claude

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.ClaudeActivitySource
import com.iaportafolio.argos.background.ClaudeWatchStore
import com.iaportafolio.argos.core.SSHServicing
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

data class ClaudeHooksUiState(
    val serverName: String = "",
    /** Sugerencia en la lista: Claude está instalado pero el indicador no. */
    val showHint: Boolean = false,
    /** Confirmación antes de tocar `~/.claude/settings.json`. */
    val confirming: Boolean = false,
    val isInstalling: Boolean = false,
    /** Resultado para el usuario (activado, ya estaba, o el error). */
    val result: UiText? = null,
)

/**
 * «Activar indicador de Claude» de un servidor (port de `installClaudeHooks(on:)` de
 * `Argos/ContentView.swift`): instala los hooks en `~/.claude/settings.json` (con copia y conservando
 * los del usuario) tras confirmar. [checkHint] decide si sugerirlo en la lista: el servidor tiene
 * `claude` pero no los hooks, y el usuario no dijo «Ahora no».
 */
class ClaudeHooksViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val hints: ClaudeWatchStore,
    private val activity: ClaudeActivitySource,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(ClaudeHooksUiState(serverName = repository.server(serverId)?.name.orEmpty()))
    val state: StateFlow<ClaudeHooksUiState> = mutableState.asStateFlow()

    private var hintChecked = false

    private suspend fun service(): SSHServicing {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.service(server)
    }

    /** Una vez por pantalla, con la conexión ya abierta (dos lecturas cortas). Un fallo no sugiere nada. */
    fun checkHint() {
        if (hintChecked || hints.isHooksHintDismissed(serverId)) return
        hintChecked = true
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo comprobar el indicador de Claude en $serverId") {
                val ssh = service()
                withContext(io) { !ssh.claudeHooksInstalled() && ssh.locateClaude() != null }
            }.onSuccess { missing -> mutableState.update { it.copy(showHint = missing) } }
        }
    }

    fun dismissHint() {
        hints.dismissHooksHint(serverId)
        mutableState.update { it.copy(showHint = false) }
    }

    fun requestInstall() = mutableState.update { it.copy(confirming = true, serverName = repository.server(serverId)?.name ?: it.serverName) }

    fun cancelInstall() = mutableState.update { it.copy(confirming = false) }

    fun confirmInstall() {
        if (state.value.isInstalling) return
        mutableState.update { it.copy(confirming = false, isInstalling = true) }
        viewModelScope.launch {
            val name = state.value.serverName
            val result = logFailures(ArgosLog.TAG_SSH, "No se pudieron instalar los hooks de Claude en $serverId") {
                val ssh = service()
                withContext(io) {
                    if (ssh.claudeHooksInstalled()) {
                        false
                    } else {
                        ssh.installClaudeHooks()
                        true
                    }
                }
            }.fold(
                onSuccess = { installed ->
                    activity.hooksInstalled(serverId)
                    UiText.res(if (installed) R.string.claude_hooks_installed else R.string.claude_hooks_already, name)
                },
                onFailure = { error -> UiText.res(R.string.claude_hooks_failed, error.userMessage) },
            )
            mutableState.update { it.copy(isInstalling = false, showHint = false, result = result) }
        }
    }

    fun resultShown() = mutableState.update { it.copy(result = null) }
}
