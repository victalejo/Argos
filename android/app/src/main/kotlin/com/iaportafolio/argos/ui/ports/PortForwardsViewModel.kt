package com.iaportafolio.argos.ui.ports

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.ports.ActivePortForward
import com.iaportafolio.argos.core.ports.ListeningPort
import com.iaportafolio.argos.core.ports.PortForwardOperations
import com.iaportafolio.argos.core.ports.parsePort
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.core.ports.PortForwardIdlePolicy
import com.iaportafolio.argos.data.PortForwardSettingsStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import com.iaportafolio.argos.ui.files.FileServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** El servicio del servidor no implementa [PortForwardOperations]. */
class PortForwardUnavailableException : Exception("La conexión no admite reenviar puertos.")

/** El mismo servicio de [ServiceProvider] (una conexión por servidor) visto como [PortForwardOperations]. */
internal suspend fun ServiceProvider.ports(server: Server): PortForwardOperations =
    service(server) as? PortForwardOperations ?: throw PortForwardUnavailableException()

/**
 * Pantalla «Puertos» de un servidor (port de `PortForwardsModel` de Apple): qué escucha en el
 * servidor y qué se reenvía a este teléfono. Los túneles viven en el servicio: cerrar la pantalla
 * no los corta. Mientras está visible se refresca cada [POLL_INTERVAL_MILLIS] ([pollWhileVisible]).
 */
class PortForwardsViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val settings: PortForwardSettingsStore,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(PortForwardsUiState(idleMinutes = settings.idleMinutes))
    val state: StateFlow<PortForwardsUiState> = mutableState.asStateFlow()

    private val openChannel = Channel<String>(Channel.BUFFERED)

    /** URL local que la pantalla debe abrir en el navegador (tras «Reenviar y abrir»). */
    val openRequests: Flow<String> = openChannel.receiveAsFlow()

    init {
        refresh()
    }

    /** Refresco mientras la pantalla está visible (lo lanza la pantalla y lo cancela al salir). */
    suspend fun pollWhileVisible() {
        while (true) {
            delay(POLL_INTERVAL_MILLIS)
            refreshNow()
        }
    }

    private suspend fun ports(): PortForwardOperations {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        mutableState.update { it.copy(serverName = server.name) }
        return services.ports(server)
    }

    fun refresh() {
        viewModelScope.launch { refreshNow() }
    }

    private suspend fun refreshNow() {
        logFailures(ArgosLog.TAG_SSH, "puertos de $serverId") {
            val ops = ports()
            val forwards = withContext(io) { ops.activePortForwards() }
            mutableState.update { it.copy(forwards = forwards) }
            val listening = withContext(io) { ops.listeningPorts() }
            mutableState.update { it.copy(listening = listening, listError = null, hasLoaded = true) }
        }.onFailure { error ->
            mutableState.update { it.copy(listError = error.toUiText(), hasLoaded = true) }
        }
    }

    // MARK: - Entrada del usuario

    fun setShowSystemPorts(show: Boolean) = mutableState.update { it.copy(showsSystemPorts = show) }

    fun setManualPort(text: String) = mutableState.update { it.copy(manualPort = text.filter(Char::isDigit).take(5)) }

    fun messageShown() = mutableState.update { it.copy(message = null) }

    /** Cierre automático: minutos sin conexiones (0 = nunca). Lo aplica el vigilante del servicio. */
    fun setIdleMinutes(minutes: Int) {
        settings.idleMinutes = minutes
        mutableState.update { it.copy(idleMinutes = settings.idleMinutes) }
    }

    // MARK: - Operaciones

    /** Abre el túnel de un puerto detectado (o reutiliza el abierto) y pide abrirlo en el navegador. */
    fun startAndOpen(port: ListeningPort) {
        viewModelScope.launch { start(port.port, port.targetHost)?.let { openChannel.send(it.localUrl) } }
    }

    fun open(forward: ActivePortForward) {
        viewModelScope.launch { openChannel.send(forward.localUrl) }
    }

    /** Reenvía un puerto escrito a mano (sirve aunque aún no escuche). */
    fun startManual() {
        val port = parsePort(state.value.manualPort)
        if (port == null) {
            mutableState.update { it.copy(message = UiText.res(R.string.ports_invalid)) }
            return
        }
        val target = state.value.listening.firstOrNull { it.port == port }?.targetHost ?: "localhost"
        viewModelScope.launch {
            if (start(port, target) != null) mutableState.update { it.copy(manualPort = "") }
        }
    }

    fun stop(forward: ActivePortForward) {
        viewModelScope.launch {
            mutableState.update { it.copy(busyPorts = it.busyPorts + forward.remotePort) }
            logFailures(ArgosLog.TAG_SSH, "cerrar túnel ${forward.remotePort}") {
                val ops = ports()
                withContext(io) { ops.stopPortForward(forward.id) }
                val forwards = withContext(io) { ops.activePortForwards() }
                mutableState.update { it.copy(forwards = forwards) }
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            mutableState.update { it.copy(busyPorts = it.busyPorts - forward.remotePort) }
        }
    }

    private suspend fun start(remotePort: Int, targetHost: String): ActivePortForward? {
        state.value.forwardFor(remotePort)?.let { return it }
        if (remotePort in state.value.busyPorts) return null
        mutableState.update { it.copy(busyPorts = it.busyPorts + remotePort) }
        val result = logFailures(ArgosLog.TAG_SSH, "abrir túnel $remotePort") {
            val ops = ports()
            val forward = withContext(io) { ops.startPortForward(remotePort, targetHost, preferredLocalPort = remotePort) }
            val forwards = withContext(io) { ops.activePortForwards() }
            mutableState.update { it.copy(forwards = forwards) }
            forward
        }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
        mutableState.update { it.copy(busyPorts = it.busyPorts - remotePort) }
        return result.getOrNull()
    }

    companion object {
        const val POLL_INTERVAL_MILLIS = 5_000L
    }
}

/** Estado de la pantalla «Puertos» (lo derivado se calcula aquí, como en Apple). */
data class PortForwardsUiState(
    val serverName: String = "",
    val listening: List<ListeningPort> = emptyList(),
    val forwards: List<ActivePortForward> = emptyList(),
    val hasLoaded: Boolean = false,
    val listError: UiText? = null,
    /** Puertos con una operación en curso (abrir/cerrar). */
    val busyPorts: Set<Int> = emptySet(),
    /** Mostrar también puertos de sistema (DNS local, sshd…). */
    val showsSystemPorts: Boolean = false,
    val manualPort: String = "",
    /** Minutos sin conexiones tras los que se cierra un túnel (0 = nunca). */
    val idleMinutes: Int = PortForwardIdlePolicy.DEFAULT_MINUTES,
    /** Último fallo de una operación; la UI lo muestra y lo borra. */
    val message: UiText? = null,
) {
    val visiblePorts: List<ListeningPort>
        get() = if (showsSystemPorts) listening else listening.filter { it.isLikelyDevServer }

    val hiddenSystemPortCount: Int get() = listening.count { !it.isLikelyDevServer }

    val canStartManual: Boolean get() = parsePort(manualPort) != null

    fun forwardFor(remotePort: Int): ActivePortForward? = forwards.firstOrNull { it.remotePort == remotePort }
}
