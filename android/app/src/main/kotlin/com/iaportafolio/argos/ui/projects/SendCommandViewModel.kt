package com.iaportafolio.argos.ui.projects

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
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

/** Diálogo «Enviar comando»: texto y sesiones en marcha que lo reciben. */
data class SendCommandState(
    val sessions: List<String>,
    val selected: Set<String>,
    val text: String = "",
    val isSending: Boolean = false,
    /** Sesiones en las que falló (se queda abierto para reintentar). */
    val error: String? = null,
) {
    val canSend: Boolean get() = text.isNotBlank() && selected.isNotEmpty() && !isSending
}

/**
 * «Enviar comando» a una o varias sesiones (como el envío múltiple del Mac): se teclea en el panel
 * activo de cada una con `tmux send-keys` (entrecomillado: llega literal) y un Intro.
 */
class SendCommandViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow<SendCommandState?>(null)
    val state: StateFlow<SendCommandState?> = mutableState.asStateFlow()

    private val mutableMessage = MutableStateFlow<UiText?>(null)
    val message: StateFlow<UiText?> = mutableMessage.asStateFlow()

    /** Abre el diálogo con [sessions] (todas marcadas salvo que [preselected] diga otra cosa). */
    fun open(sessions: List<String>, preselected: Set<String> = sessions.toSet()) {
        if (sessions.isEmpty()) return
        mutableState.value = SendCommandState(sessions, preselected.intersect(sessions.toSet()))
    }

    fun onText(text: String) = mutableState.update { it?.copy(text = text, error = null) }

    fun toggle(session: String) = mutableState.update { state ->
        state?.copy(selected = if (session in state.selected) state.selected - session else state.selected + session)
    }

    fun dismiss() = mutableState.update { if (it?.isSending == true) it else null }

    fun send() {
        val current = state.value ?: return
        if (!current.canSend) return
        mutableState.value = current.copy(isSending = true, error = null)
        viewModelScope.launch {
            val failed = mutableListOf<String>()
            val targets = current.sessions.filter { it in current.selected }
            var lastError: String? = null
            for (session in targets) {
                logFailures(ArgosLog.TAG_SSH, "No se pudo enviar el comando a una sesión de $serverId") {
                    val server = repository.server(serverId) ?: throw FileServerMissingException()
                    val service = services.service(server)
                    withContext(io) { service.sendKeys(session, current.text, enter = true) }
                }.onFailure { error ->
                    failed += session
                    lastError = error.userMessage
                }
            }
            if (failed.isEmpty()) {
                mutableState.value = null
                mutableMessage.value = UiText.res(R.string.send_command_sent, targets.size)
            } else {
                mutableState.update {
                    it?.copy(isSending = false, selected = failed.toSet(), error = "${failed.joinToString(", ")}: $lastError")
                }
            }
        }
    }

    fun messageShown() {
        mutableMessage.value = null
    }
}
