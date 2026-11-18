package com.iaportafolio.argos.ui.terminal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.ClaudeActivitySource
import com.iaportafolio.argos.background.ViewedWindow
import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.core.tmux.TmuxPaneDirection
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.core.tmux.WindowColor
import com.iaportafolio.argos.core.tmux.WindowNameValidator
import com.iaportafolio.argos.core.tmux.WindowCloseDecision
import com.iaportafolio.argos.core.tmux.WindowTabs
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import com.iaportafolio.argos.ui.files.FileServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class TerminalWindowsUiState(
    /** Ventanas de la sesión; vacío mientras no se han leído (la barra no se muestra). */
    val windows: List<TmuxWindow> = emptyList(),
    /** Agentes instalados en el servidor (`null` mientras no se sabe: todos activos). */
    val installedAgents: Set<CodingAgent>? = null,
    /** Ventana pendiente de confirmar su cierre (corre algo en ella). */
    val closing: TmuxWindow? = null,
    val message: UiText? = null,
    /** Estado de Claude Code por índice de ventana (insignia de cada pestaña). */
    val claudeWindows: Map<Int, ClaudeActivity> = emptyMap(),
    /** Ventana que se está renombrando (diálogo abierto). */
    val renaming: WindowRename? = null,
)

/** Diálogo «Renombrar ventana»: el error es el del validador de tmux, en vivo. */
data class WindowRename(val window: TmuxWindow, val text: String, val error: String? = null)

/**
 * Pestañas de las ventanas tmux de una sesión (port de la parte de ventanas de `TerminalScreen`
 * de iOS): las relee mientras el terminal está a la vista y cambia, abre y cierra ventanas. La
 * lógica de qué es cada pestaña y cómo se cierra es la de [WindowTabs].
 */
class TerminalWindowsViewModel(
    private val serverId: String,
    private val sessionName: String,
    /** Carpeta del proyecto (`null` en una sesión suelta): ahí arrancan los agentes. */
    private val projectPath: String?,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
    private val claude: ClaudeActivitySource = ClaudeActivitySource.None,
) : ViewModel() {

    private val mutableState = MutableStateFlow(TerminalWindowsUiState())
    val state: StateFlow<TerminalWindowsUiState> = mutableState.asStateFlow()

    /** Serializa leer-y-publicar: una lectura vieja no puede pisar a una más reciente. */
    private val refreshMutex = Mutex()

    /** Un solo intento por tanda de sondeo: no se abre un canal extra cada pocos segundos. */
    private var triedInstalledAgents = false

    /** Lo último que se contó a [claude] como «en pantalla» (para no pisar a otro terminal al salir). */
    private var viewed: ViewedWindow? = null

    init {
        viewModelScope.launch {
            claude.activity.map { it[serverId]?.windows(sessionName).orEmpty() }.distinctUntilChanged()
                .collect { windows -> mutableState.update { it.copy(claudeWindows = windows) } }
        }
    }

    private suspend fun service(): SSHServicing {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.service(server)
    }

    /**
     * Relee las ventanas mientras la pantalla está visible (la lanza la pantalla y la cancela al
     * salir). Si el servidor no responde, espacia los intentos para no competir con la
     * reconexión del propio terminal.
     */
    suspend fun pollWhileVisible() {
        triedInstalledAgents = false
        try {
            markViewing()
            pollLoop(POLL_INTERVAL_MILLIS)
        } finally {
            // Ya no se ve: vuelve a avisarse de esta ventana (salvo que otro terminal la tenga delante).
            viewed?.let { mine -> claude.clearViewing(mine) }
            viewed = null
        }
    }

    /** La ventana activa es la que se mira: de ella no se avisa y se retira su aviso. */
    private fun markViewing() {
        val window = ViewedWindow(serverId, sessionName, state.value.windows.firstOrNull { it.isActive }?.index)
        if (window == viewed) return
        viewed = window
        claude.setViewing(window)
    }

    private suspend fun pollLoop(initial: Long) {
        var interval = initial
        while (true) {
            val ok = refreshNow()
            markViewing()
            if (ok && state.value.installedAgents == null && !triedInstalledAgents) {
                triedInstalledAgents = true
                loadInstalledAgents()
            }
            interval = if (ok) POLL_INTERVAL_MILLIS else (interval * 2).coerceAtMost(MAX_POLL_INTERVAL_MILLIS)
            delay(interval)
        }
    }

    private suspend fun refreshNow(): Boolean = logFailures(ArgosLog.TAG_TERMINAL, "ventanas de «$sessionName» en $serverId") {
        fetchWindows(service())
    }.isSuccess

    /** Lee las ventanas de tmux y las publica. */
    private suspend fun fetchWindows(ssh: SSHServicing): List<TmuxWindow> = refreshMutex.withLock {
        val fresh = withContext(io) { ssh.listWindows(sessionName) }
        mutableState.update { state ->
            // tmux reutiliza los índices: la confirmación solo sigue en pie si es LA MISMA ventana.
            val closing = state.closing?.takeIf { pending -> fresh.any { it.isSameWindowAs(pending) } }
            state.copy(windows = fresh, closing = closing)
        }
        fresh
    }

    private fun TmuxWindow.isSameWindowAs(other: TmuxWindow): Boolean =
        index == other.index && name == other.name && currentCommand == other.currentCommand

    private suspend fun loadInstalledAgents() {
        logFailures(ArgosLog.TAG_TERMINAL, "agentes instalados en $serverId") {
            val ssh = service()
            withContext(io) { ssh.installedCodingAgents() }
        }.onSuccess { agents -> mutableState.update { it.copy(installedAgents = agents) } }
    }

    // MARK: - Acciones

    /** La lista puede ir por detrás de tmux: se selecciona siempre (es idempotente). */
    fun select(window: TmuxWindow) {
        // Respuesta inmediata; la lectura posterior confirma (o corrige) la pestaña activa.
        mutableState.update { state -> state.copy(windows = state.windows.map { it.copy(isActive = it.index == window.index) }) }
        if (viewed != null) markViewing()
        run("cambiar a la ventana ${window.index}") { it.selectWindow(sessionName, window.index) }
    }

    fun newWindow() = run("abrir una ventana") { it.newWindow(sessionName) }

    /** Abre una ventana con [agent] en la carpeta del proyecto (o la del panel activo). */
    fun newAgentWindow(agent: CodingAgent) =
        run("lanzar ${agent.displayName}") { it.newAgentWindow(sessionName, agent, projectPath) }

    /**
     * Cerrar la ventana [index]: directo si es un shell ocioso, con confirmación si corre algo y
     * nunca la última (mataría la sesión). Decide con la lista recién leída de tmux.
     */
    fun requestClose(index: Int) {
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_TERMINAL, "ventanas de «$sessionName» para cerrar") {
                val ssh = service()
                val fresh = fetchWindows(ssh)
                val target = fresh.firstOrNull { it.index == index } ?: return@logFailures
                when (WindowTabs.closeDecision(target, fresh.size)) {
                    WindowCloseDecision.BLOCKED ->
                        mutableState.update { it.copy(message = UiText.res(R.string.terminal_window_last)) }
                    WindowCloseDecision.IMMEDIATE -> {
                        withContext(io) { ssh.killWindow(sessionName, target.index) }
                        fetchWindows(ssh)
                    }
                    WindowCloseDecision.CONFIRM -> mutableState.update { it.copy(closing = target) }
                }
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
        }
    }

    /**
     * Cierra la ventana confirmada, comprobando antes contra tmux que sigue siendo la misma y que
     * no se ha quedado como la última (cerrarla mataría la sesión).
     */
    fun confirmClose() {
        val target = state.value.closing ?: return
        mutableState.update { it.copy(closing = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_TERMINAL, "No se pudo cerrar la ventana ${target.index} en «$sessionName»") {
                val ssh = service()
                val fresh = fetchWindows(ssh)
                val current = fresh.firstOrNull { it.isSameWindowAs(target) } ?: return@logFailures
                if (WindowTabs.closeDecision(current, fresh.size) == WindowCloseDecision.BLOCKED) {
                    mutableState.update { it.copy(message = UiText.res(R.string.terminal_window_last)) }
                    return@logFailures
                }
                withContext(io) { ssh.killWindow(sessionName, current.index) }
                fetchWindows(ssh)
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
        }
    }

    fun dismissClose() = mutableState.update { it.copy(closing = null) }

    // MARK: - Paneles (ventana activa)

    /** Divide el panel activo: [vertical] = uno encima de otro; si no, lado a lado. */
    fun splitPane(vertical: Boolean) = run("dividir el panel") { it.splitPane(sessionName, vertical) }

    fun selectPane(direction: TmuxPaneDirection) = run("cambiar de panel") { it.selectPane(sessionName, direction) }

    /** Amplía el panel activo a toda la ventana (o lo devuelve a su sitio). */
    fun zoomPane() = run("ampliar el panel") { it.zoomPane(sessionName) }

    /** Cierra el panel activo; nunca el único de la ventana (para eso, cerrar la ventana). */
    fun killPane() {
        val active = state.value.windows.firstOrNull { it.isActive }
        if (active != null && active.paneCount <= 1) {
            mutableState.update { it.copy(message = UiText.res(R.string.terminal_pane_last)) }
            return
        }
        run("cerrar el panel") { it.killPane(sessionName) }
    }

    // MARK: - Renombrar y color

    fun requestRename(window: TmuxWindow) = mutableState.update { it.copy(renaming = WindowRename(window, window.name)) }

    fun onRenameText(text: String) = mutableState.update { state ->
        state.renaming?.let { state.copy(renaming = it.copy(text = text, error = WindowNameValidator.liveValidationMessage(text))) } ?: state
    }

    fun dismissRename() = mutableState.update { it.copy(renaming = null) }

    /** Renombra con el nombre validado (como el Mac: `WindowNameValidator` antes de enviar nada). */
    fun confirmRename() {
        val rename = state.value.renaming ?: return
        val name = try {
            WindowNameValidator.validate(rename.text)
        } catch (invalid: WindowNameValidator.ValidationError) {
            return mutableState.update { it.copy(renaming = rename.copy(error = invalid.message)) }
        }
        mutableState.update { it.copy(renaming = null) }
        if (name == rename.window.name) return
        run("renombrar la ventana ${rename.window.index}") { it.renameWindow(sessionName, rename.window.index, name) }
    }

    /** Color de la pestaña (`null` = quitarlo); se guarda en tmux (`@argos_color`) y lo ven todos los dispositivos. */
    fun setColor(window: TmuxWindow, color: WindowColor?) {
        mutableState.update { state -> state.copy(windows = state.windows.map { if (it.index == window.index) it.copy(color = color) else it }) }
        run("cambiar el color de la ventana ${window.index}") { it.setWindowColor(sessionName, window.index, color) }
    }

    fun messageShown() = mutableState.update { it.copy(message = null) }

    private fun run(what: String, action: suspend (SSHServicing) -> Unit) {
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_TERMINAL, "No se pudo $what en «$sessionName»") {
                val ssh = service()
                withContext(io) { action(ssh) }
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            refreshNow()
        }
    }

    companion object {
        /** Cada cuánto se releen las ventanas con el terminal a la vista. */
        const val POLL_INTERVAL_MILLIS = 4_000L

        /** Tope del espaciado de reintentos cuando el servidor no responde. */
        const val MAX_POLL_INTERVAL_MILLIS = 60_000L
    }
}
