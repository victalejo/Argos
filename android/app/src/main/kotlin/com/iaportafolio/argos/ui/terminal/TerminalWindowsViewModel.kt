package com.iaportafolio.argos.ui.terminal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.core.tmux.TmuxWindow
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
)

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
) : ViewModel() {

    private val mutableState = MutableStateFlow(TerminalWindowsUiState())
    val state: StateFlow<TerminalWindowsUiState> = mutableState.asStateFlow()

    /** Serializa leer-y-publicar: una lectura vieja no puede pisar a una más reciente. */
    private val refreshMutex = Mutex()

    /** Un solo intento por tanda de sondeo: no se abre un canal extra cada pocos segundos. */
    private var triedInstalledAgents = false

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
        var interval = POLL_INTERVAL_MILLIS
        triedInstalledAgents = false
        while (true) {
            val ok = refreshNow()
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
