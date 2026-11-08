package com.iaportafolio.argos.ui.sessions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.tmux.SessionGrouping
import com.iaportafolio.argos.core.tmux.SessionNameValidator
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Sesiones tmux de UN servidor (port de `SessionsViewModel` de Apple): al conectar asegura
 * tmux (detecta → instala si hay sudo sin contraseña → configura) y luego lista, agrupando
 * con [SessionGrouping].
 */
class SessionsViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val hostKeys: HostKeyTrustStore,
    private val io: CoroutineDispatcher,
) : ViewModel(), SessionsActions {

    private val mutableState = MutableStateFlow(SessionsUiState(serverName = repository.server(serverId)?.name.orEmpty()))
    val state: StateFlow<SessionsUiState> = mutableState.asStateFlow()

    private var loadJob: Job? = null

    /** Señal interna: el arranque se detuvo con la instrucción manual de instalar tmux. */
    private class TmuxMissingStop : Exception()

    init {
        viewModelScope.launch {
            repository.servers.collect { servers ->
                servers.firstOrNull { it.id == serverId }?.let { server ->
                    mutableState.update { it.copy(serverName = server.name) }
                }
            }
        }
        load()
    }

    // MARK: - Conexión

    /** Conecta desde cero (arranque de tmux incluido). Cancela una carga anterior. */
    override fun load() {
        loadJob?.cancel()
        mutableState.update { it.copy(load = SessionsLoad.Connecting(ConnectStep.VERIFYING), isRefreshing = false) }
        loadJob = viewModelScope.launch {
            val server = repository.server(serverId)
            if (server == null) {
                mutableState.update { it.copy(load = SessionsLoad.ServerMissing, groups = emptyList()) }
                return@launch
            }
            logFailures(ArgosLog.TAG_SSH, "No se pudo cargar las sesiones de ${server.endpoint}") {
                val service = services.service(server)
                ensureTmuxEnvironment(service)
                step(ConnectStep.LOADING)
                withContext(io) { service.listSessions() }
            }.onSuccess { sessions ->
                mutableState.update { it.copy(load = SessionsLoad.Loaded, groups = SessionGrouping.groups(sessions)) }
            }.onFailure { error -> mutableState.update { it.copy(load = loadFailure(error), groups = emptyList()) } }
        }
    }

    /** Pull-to-refresh: con la lista visible solo re-lista; si no, reconecta. */
    override fun refresh() {
        if (state.value.load != SessionsLoad.Loaded) {
            load()
            return
        }
        if (state.value.isRefreshing) return
        mutableState.update { it.copy(isRefreshing = true) }
        loadJob = viewModelScope.launch {
            relist()
            mutableState.update { it.copy(isRefreshing = false) }
        }
    }

    /** Huella cambiada y el usuario confía en la nueva: olvida la guardada y reconecta. */
    override fun forgetHostKeyAndRetry() {
        val server = repository.server(serverId) ?: return load()
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_HOST_KEY, "No se pudo olvidar la huella de ${server.endpoint}") {
                withContext(io) { hostKeys.forget(server.endpoint) }
                services.invalidate(server.id)
            }.onSuccess { load() }
                .onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
        }
    }

    private suspend fun ensureTmuxEnvironment(service: SSHServicing) {
        step(ConnectStep.VERIFYING)
        if (!withContext(io) { service.isTmuxInstalled() }) {
            if (!withContext(io) { service.canUseSudoNonInteractive() }) throw TmuxMissingStop()
            step(ConnectStep.INSTALLING)
            withContext(io) { service.installTmuxWithApt() }
        }
        if (!withContext(io) { service.tmuxConfigExists() }) {
            step(ConnectStep.CONFIGURING)
            withContext(io) { service.writeDefaultTmuxConfig() }
        }
        // OSC 52 (portapapeles) best-effort: el contrato dice que nunca lanza.
        withContext(io) { service.enableClipboardForwarding() }
    }

    private fun step(step: ConnectStep) = mutableState.update { it.copy(load = SessionsLoad.Connecting(step)) }

    private fun loadFailure(error: Throwable): SessionsLoad {
        val mismatch = error.causeChain().filterIsInstance<HostKeyMismatchException>().firstOrNull()
        return when {
            mismatch != null -> SessionsLoad.HostKeyChanged(mismatch.userMessage)
            error is TmuxMissingStop || error is SSHServiceError.TmuxNotInstalled -> SessionsLoad.TmuxMissing
            else -> SessionsLoad.Failed(error.userMessage)
        }
    }

    private fun Throwable.causeChain(): Sequence<Throwable> =
        generateSequence(this) { current -> current.cause?.takeIf { it !== current } }.take(MAX_CAUSE_DEPTH)

    /**
     * Re-lista sin repetir el arranque. Un fallo con la lista visible se avisa sin borrarla
     * (salvo huella cambiada o tmux desaparecido, que cambian de pantalla).
     */
    private suspend fun relist() {
        val server = repository.server(serverId) ?: return mutableState.update { it.copy(load = SessionsLoad.ServerMissing) }
        logFailures(ArgosLog.TAG_SSH, "No se pudo re-listar las sesiones de ${server.endpoint}") {
            withContext(io) { services.service(server).listSessions() }
        }.onSuccess { sessions ->
            mutableState.update { it.copy(load = SessionsLoad.Loaded, groups = SessionGrouping.groups(sessions)) }
        }.onFailure { error ->
            when (val failure = loadFailure(error)) {
                is SessionsLoad.Failed -> mutableState.update { it.copy(message = error.toUiText()) }
                else -> mutableState.update { it.copy(load = failure, groups = emptyList()) }
            }
        }
    }

    // MARK: - Diálogos

    override fun openCreate() = mutableState.update { it.copy(dialog = SessionDialog.Create()) }

    override fun openRename(session: TmuxSession) =
        mutableState.update { it.copy(dialog = SessionDialog.Rename(session, text = session.name)) }

    override fun requestKill(session: TmuxSession) = mutableState.update { it.copy(dialog = SessionDialog.ConfirmKill(session)) }

    override fun dismissDialog() = mutableState.update { state ->
        val submitting = (state.dialog as? SessionDialog.NameInput)?.isSubmitting == true
        if (submitting) state else state.copy(dialog = null)
    }

    override fun onDialogTextChange(text: String) = mutableState.update { state ->
        val error = SessionNameValidator.liveValidationMessage(text)
        when (val dialog = state.dialog) {
            is SessionDialog.Create -> state.copy(dialog = dialog.copy(text = text, error = error))
            is SessionDialog.Rename -> state.copy(dialog = dialog.copy(text = text, error = error))
            is SessionDialog.ConfirmKill, null -> state
        }
    }

    /** Crear o renombrar con el nombre tecleado. Los errores se muestran dentro del diálogo. */
    override fun submitDialog() {
        val dialog = state.value.dialog as? SessionDialog.NameInput ?: return
        if (dialog.isSubmitting) return
        val name = try {
            SessionNameValidator.validate(dialog.text)
        } catch (invalid: SessionNameValidator.ValidationError) {
            return updateNameDialog { it.withError(invalid.userMessage) }
        }
        if (dialog is SessionDialog.Rename && name == dialog.session.name) {
            mutableState.update { it.copy(dialog = null) }
            return
        }
        val server = repository.server(serverId) ?: return mutableState.update { it.copy(load = SessionsLoad.ServerMissing, dialog = null) }
        updateNameDialog { it.submitting(true) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo crear/renombrar una sesión en ${server.endpoint}") {
                val service = services.service(server)
                withContext(io) {
                    when (dialog) {
                        is SessionDialog.Create -> service.createSession(name)
                        is SessionDialog.Rename -> service.renameSession(dialog.session.name, name)
                    }
                }
            }.onSuccess {
                mutableState.update { it.copy(dialog = null) }
                relist()
            }.onFailure { error -> updateNameDialog { it.submitting(false).withError(error.userMessage) } }
        }
    }

    override fun confirmKill() {
        val session = (state.value.dialog as? SessionDialog.ConfirmKill)?.session ?: return
        mutableState.update { it.copy(dialog = null) }
        val server = repository.server(serverId) ?: return mutableState.update { it.copy(load = SessionsLoad.ServerMissing) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo cerrar una sesión en ${server.endpoint}") {
                val service = services.service(server)
                withContext(io) { service.killSession(session.name) }
            }.onSuccess {
                relist()
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
        }
    }

    // MARK: - Varios

    override fun messageShown() = mutableState.update { it.copy(message = null) }

    private fun updateNameDialog(change: (SessionDialog.NameInput) -> SessionDialog.NameInput) =
        mutableState.update { state ->
            val dialog = state.dialog as? SessionDialog.NameInput
            if (dialog == null) state else state.copy(dialog = change(dialog))
        }

    private fun SessionDialog.NameInput.withError(error: String?): SessionDialog.NameInput = when (this) {
        is SessionDialog.Create -> copy(error = error)
        is SessionDialog.Rename -> copy(error = error)
    }

    private fun SessionDialog.NameInput.submitting(value: Boolean): SessionDialog.NameInput = when (this) {
        is SessionDialog.Create -> copy(isSubmitting = value)
        is SessionDialog.Rename -> copy(isSubmitting = value)
    }

    private companion object {
        const val MAX_CAUSE_DEPTH = 8
    }
}
