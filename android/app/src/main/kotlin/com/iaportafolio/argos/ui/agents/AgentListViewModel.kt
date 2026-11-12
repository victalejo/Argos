package com.iaportafolio.argos.ui.agents

import com.iaportafolio.argos.background.AgentAttentionTracker
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.agent.PersistentAgentInfo
import com.iaportafolio.argos.core.agent.PersistentAgentScript
import com.iaportafolio.argos.core.agent.PersistentAgentSession
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.data.ClaudeTokenStore
import com.iaportafolio.argos.data.ClaudeTokenValidation
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.terminal.TerminalServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Agentes persistentes de un proyecto (port de `AgentsView` de iOS): los del servidor filtrados
 * por la carpeta del proyecto. Antes de crear uno comprueba la sesión de Claude (como
 * `AgentPanelView` del Mac): sin sesión ni token ofrece pegar un token o iniciar sesión.
 */
class AgentListViewModel(
    private val serverId: String,
    projectName: String,
    private val workingDirectory: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val tokens: ClaudeTokenStore,
    private val permissions: AgentPermissionStore,
    private val io: CoroutineDispatcher,
    private val attention: AgentAttentionTracker = AgentAttentionTracker.None,
) : ViewModel() {

    private val mutableState = MutableStateFlow(
        AgentListUiState(
            projectName = projectName,
            workingDirectory = workingDirectory,
            permissions = permissions.selection(serverId, workingDirectory),
            serverName = repository.server(serverId)?.name.orEmpty(),
        ),
    )
    val state: StateFlow<AgentListUiState> = mutableState.asStateFlow()

    private val eventChannel = Channel<AgentListEvent>(Channel.BUFFERED)
    val events: Flow<AgentListEvent> = eventChannel.receiveAsFlow()

    private var refreshJob: Job? = null
    private var infos: List<PersistentAgentInfo> = emptyList()

    /** Se pidió crear un agente y faltaba la sesión: continúa al completar la autenticación. */
    private var createAfterAuth = false
    private val redactor = SecretRedactor()

    init {
        // El ajuste global puede cambiar con esta pantalla en la pila.
        viewModelScope.launch {
            permissions.values.collect {
                mutableState.update { it.copy(permissions = permissions.selection(serverId, workingDirectory)) }
            }
        }
        refresh()
    }

    // MARK: - Lista

    /** Relee los agentes y la sesión de Claude (al abrir, al volver, al tirar de la lista). */
    fun refresh() {
        refreshJob?.cancel()
        mutableState.update {
            if (it.load is AgentListLoad.Loaded) it.copy(isRefreshing = true) else it.copy(load = AgentListLoad.Loading)
        }
        refreshJob = viewModelScope.launch {
            agentFailures("No se pudieron leer los agentes de $serverId") {
                val ssh = service()
                val hasToken = withContext(io) { tokens.hasToken() }
                val listed = withContext(io) { PersistentAgentSession.list(ssh) }
                applyList(listed, hasToken)
                refreshClaude(ssh)
            }.onFailure { error ->
                mutableState.update { state ->
                    if (state.load is AgentListLoad.Loaded) {
                        state.copy(message = error.toAgentUiText(redactor))
                    } else {
                        state.copy(load = AgentListLoad.Failed(error.toAgentUiText(redactor)))
                    }
                }
            }
            mutableState.update { it.copy(isRefreshing = false) }
            // Con un diálogo abierto el usuario aún está decidiendo (p. ej. volvió a primer plano).
            if (createAfterAuth && state.value.dialog == null) {
                createAfterAuth = false
                val signedIn = state.value.claude is ClaudeAvailability.SignedIn
                if (signedIn || state.value.hasSavedToken) createAgent()
            }
        }
    }

    private fun applyList(listed: List<PersistentAgentInfo>, hasToken: Boolean) {
        infos = listed.filter { it.meta.workingDirectory == workingDirectory }.sortedByDescending { it.meta.createdAt }
        // Un servidor sin agentes en marcha deja de revisarse en segundo plano; al arrancar o
        // reanudar uno desde esta lista (sin abrir su chat) hay que volver a apuntarlo.
        if (listed.any { it.isAlive }) attention.agentOpened(serverId)
        mutableState.update { state ->
            val busy = state.agents.filter { it.isBusy }.map { it.id }.toSet()
            state.copy(
                load = AgentListLoad.Loaded,
                hasSavedToken = hasToken,
                agents = infos.map {
                    AgentRow(it.id, it.meta.title, it.meta.createdAt, it.isAlive, it.meta.resolvedPermissionMode, it.id in busy)
                },
            )
        }
    }

    /** Fallar aquí no oculta la lista: la sesión se volverá a comprobar al crear un agente. */
    private suspend fun refreshClaude(ssh: SSHServicing) {
        val exec = ssh as? AgentExecStreaming ?: return
        agentFailures("No se pudo comprobar la sesión de Claude en $serverId") {
            withContext(io) { exec.claudeAuthStatus() }
        }.onSuccess { status -> mutableState.update { it.copy(claude = availability(status)) } }
    }

    private fun availability(status: ClaudeAuthStatus?): ClaudeAvailability = when {
        status == null -> ClaudeAvailability.Missing
        status.loggedIn -> ClaudeAvailability.SignedIn(status.subscriptionType, status.email)
        else -> ClaudeAvailability.SignedOut
    }

    // MARK: - Crear

    fun createAgent() {
        if (state.value.isCreating) return
        mutableState.update { it.copy(isCreating = true) }
        viewModelScope.launch {
            var createdId: String? = null
            var failureRedactor = SecretRedactor()
            agentFailures("No se pudo crear un agente en $serverId") {
                val ssh = service()
                val exec = ssh.agentExec()
                val status = withContext(io) { exec.claudeAuthStatus() }
                mutableState.update { it.copy(claude = availability(status)) }
                if (status != null) {
                    val token = launchToken(status.loggedIn)
                    if (token != null) failureRedactor = SecretRedactor(token)
                    if (!status.loggedIn && token == null) {
                        createAfterAuth = true
                        mutableState.update { it.copy(dialog = AgentListDialog.AuthRequired, tokenError = null) }
                    } else {
                        createdId = PersistentAgentSession.launch(
                            service = ssh,
                            exec = exec,
                            workingDirectory = workingDirectory,
                            title = state.value.projectName,
                            oauthToken = token,
                            // Su valor por defecto es otro: hay que pasar siempre el efectivo.
                            permissionMode = permissions.effectiveMode(serverId, workingDirectory),
                            scope = viewModelScope,
                        ).id
                    }
                }
            }.onFailure { error ->
                mutableState.update { it.copy(message = error.toAgentUiText(failureRedactor)) }
            }
            mutableState.update { it.copy(isCreating = false) }
            createdId?.let {
                eventChannel.send(AgentListEvent.OpenAgent(it))
                refresh()
            }
        }
    }

    /** Con sesión en el servidor un token ilegible no impide lanzar; sin ella, es el error a mostrar. */
    private suspend fun launchToken(loggedIn: Boolean): String? {
        val result = agentFailures("No se pudo leer el token de Claude") { withContext(io) { tokens.read() } }
        return if (loggedIn) result.getOrNull() else result.getOrThrow()
    }

    // MARK: - Abrir, parar, reanudar, borrar

    fun openAgent(agentId: String) {
        viewModelScope.launch { eventChannel.send(AgentListEvent.OpenAgent(agentId)) }
    }

    fun stop(agentId: String) = runOnAgent(agentId, "parar") { ssh ->
        withContext(io) { ssh.runAgentScript(PersistentAgentScript.stop(agentId, delete = false)) }
    }

    /**
     * Pide reanudar. `meta.json` puede haberlo editado el propio agente, así que los modos que
     * actúan sin preguntar exigen que el usuario los confirme ([confirmResume]).
     */
    fun resume(agentId: String) {
        val info = infos.firstOrNull { it.id == agentId } ?: return
        if (info.meta.resumeRequiresConfirmation) {
            mutableState.update { it.copy(dialog = AgentListDialog.ConfirmResume(agentId, info.meta.resolvedPermissionMode)) }
        } else {
            performResume(info)
        }
    }

    fun confirmResume() {
        val dialog = state.value.dialog as? AgentListDialog.ConfirmResume ?: return
        val info = infos.firstOrNull { it.id == dialog.agentId }
        // La lista se refresca sola: si el modo cambió desde que se preguntó, lo aprobado ya no
        // es lo que se lanzaría (el `meta.json` lo puede editar el agente). Se vuelve a preguntar.
        if (info != null && info.meta.resolvedPermissionMode != dialog.mode) {
            dismissDialog()
            resume(info.id)
            return
        }
        dismissDialog()
        info?.let(::performResume)
    }

    /** Relanza el proceso; el chat se engancha al abrirlo. El token solo viaja por stdin. */
    private fun performResume(info: PersistentAgentInfo) {
        val agentId = info.id
        runOnAgent(agentId, "reanudar") { ssh ->
            val token = withContext(io) { tokens.read() }
            val session = PersistentAgentSession(ssh, ssh.agentExec(), info, viewModelScope)
            session.resume(token)
            session.detach()
            session.state.value.lastError?.let { failure ->
                throw AgentActionException(SecretRedactor(token).redact(failure))
            }
        }
    }

    fun requestDelete(agentId: String) {
        val agent = state.value.agents.firstOrNull { it.id == agentId } ?: return
        mutableState.update { it.copy(dialog = AgentListDialog.ConfirmDelete(agentId, agent.title)) }
    }

    fun confirmDelete() {
        val dialog = state.value.dialog as? AgentListDialog.ConfirmDelete ?: return
        dismissDialog()
        runOnAgent(dialog.agentId, "borrar") { ssh ->
            withContext(io) { ssh.runAgentScript(PersistentAgentScript.stop(dialog.agentId, delete = true)) }
        }
    }

    private fun runOnAgent(agentId: String, what: String, action: suspend (SSHServicing) -> Unit) {
        if (state.value.agents.firstOrNull { it.id == agentId }?.isBusy != false) return
        setBusy(agentId, true)
        viewModelScope.launch {
            agentFailures("No se pudo $what el agente $agentId") { action(service()) }
                .onFailure { error -> mutableState.update { it.copy(message = error.toAgentUiText(redactor)) } }
            setBusy(agentId, false)
            refresh()
        }
    }

    private fun setBusy(agentId: String, busy: Boolean) = mutableState.update { state ->
        state.copy(agents = state.agents.map { if (it.id == agentId) it.copy(isBusy = busy) else it })
    }

    // MARK: - Permisos

    fun showPermissionsDialog() = mutableState.update { it.copy(dialog = AgentListDialog.Permissions) }

    /** Afecta a los agentes nuevos; [mode] nulo vuelve al ajuste global. */
    fun setPermissionChoice(mode: ClaudeAgentCommand.PermissionMode?) =
        permissions.setProjectChoice(serverId, workingDirectory, mode)

    // MARK: - Autenticación

    /** Cierra el diálogo actual; abandona también la creación que estuviera a la espera. */
    fun dismissDialog() {
        createAfterAuth = false
        mutableState.update { it.copy(dialog = null, tokenError = null) }
    }

    /** Muestra el diálogo del token; conserva la creación a la espera si venía de ella. */
    fun showTokenDialog() = mutableState.update { it.copy(dialog = AgentListDialog.Token, tokenError = null) }

    /** Guarda el token cifrado y, si se estaba creando un agente, continúa. */
    fun saveToken(raw: String) {
        val token = ClaudeTokenValidation.normalize(raw)
        if (token == null) {
            mutableState.update { it.copy(tokenError = UiText.res(R.string.agents_token_invalid)) }
            return
        }
        viewModelScope.launch {
            agentFailures("No se pudo guardar el token de Claude") {
                withContext(io) { tokens.save(token) }
            }.onSuccess {
                val resume = createAfterAuth
                createAfterAuth = false
                mutableState.update { it.copy(hasSavedToken = true, dialog = null, tokenError = null) }
                if (resume) createAgent()
            }.onFailure {
                // El mensaje de un fallo criptográfico no aporta: se dice qué hacer.
                mutableState.update { it.copy(tokenError = UiText.res(R.string.agents_token_save_failed)) }
            }
        }
    }

    fun deleteToken() {
        viewModelScope.launch {
            agentFailures("No se pudo borrar el token de Claude") {
                withContext(io) { tokens.delete() }
            }.onSuccess {
                mutableState.update { it.copy(hasSavedToken = false, message = UiText.res(R.string.agents_token_deleted)) }
            }.onFailure { error ->
                mutableState.update { it.copy(message = error.toAgentUiText(redactor)) }
            }
        }
    }

    /** Abre el login guiado. Al volver, [refresh] retoma la creación si ya hay sesión. */
    fun startLogin() {
        mutableState.update { it.copy(dialog = null, tokenError = null) }
        viewModelScope.launch { eventChannel.send(AgentListEvent.OpenLogin) }
    }

    fun messageShown() = mutableState.update { it.copy(message = null) }

    private suspend fun service(): SSHServicing {
        val server: Server = repository.server(serverId) ?: throw TerminalServerMissingException()
        return services.service(server)
    }
}

/** Una acción sobre un agente falló y ya trae su mensaje (sin secretos). */
private class AgentActionException(message: String) : Exception(message)
