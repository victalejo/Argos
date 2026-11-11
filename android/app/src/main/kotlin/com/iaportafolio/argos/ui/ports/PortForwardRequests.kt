package com.iaportafolio.argos.ui.ports

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.ports.PortForwardRequest
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.asString
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

/** Estado del aviso de solicitudes de Claude. */
data class PortForwardRequestsUiState(
    /** Solicitud que se está mostrando (la más antigua pendiente). */
    val current: PortForwardRequest? = null,
    val serverName: String = "",
    val isOpening: Boolean = false,
    /** Fallo al abrir el túnel; la UI lo muestra y lo borra. */
    val error: UiText? = null,
)

/**
 * Solicitudes de Claude para abrir un puerto (`argos-ports open`, port de `PortForwardRequestsModel`
 * de Apple). Se vigilan mientras un proyecto del servidor está en pantalla; SOLO se abre el túnel si
 * el usuario acepta.
 */
class PortForwardRequestsViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(PortForwardRequestsUiState())
    val state: StateFlow<PortForwardRequestsUiState> = mutableState.asStateFlow()

    private val openChannel = Channel<String>(Channel.BUFFERED)

    /** URL local que la pantalla debe abrir tras aceptar. */
    val openRequests: Flow<String> = openChannel.receiveAsFlow()

    /** Ya respondidas: no se vuelven a mostrar aunque el borrado en el servidor tarde. */
    private val handled = mutableSetOf<Int>()

    suspend fun pollWhileVisible() {
        while (true) {
            refreshNow()
            delay(POLL_INTERVAL_MILLIS)
        }
    }

    internal suspend fun refreshNow() {
        if (state.value.isOpening) return
        logFailures(ArgosLog.TAG_SSH, "solicitudes de puertos de $serverId") {
            val server = repository.server(serverId) ?: throw FileServerMissingException()
            val pending = withContext(io) { services.ports(server).pendingPortForwardRequests() }
            handled.retainAll(pending.map { it.port }.toSet())
            mutableState.update { state ->
                state.copy(serverName = server.name, current = pending.firstOrNull { it.port !in handled })
            }
        }
    }

    /** Abre el túnel (o reutiliza el abierto), retira la solicitud y pide abrir el navegador. */
    fun accept() {
        val request = state.value.current ?: return
        handled += request.port
        mutableState.update { it.copy(current = null, isOpening = true) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "aceptar solicitud ${request.port}") {
                val server = repository.server(serverId) ?: throw FileServerMissingException()
                val ops = services.ports(server)
                withContext(io) { ops.dismissPortForwardRequest(request.port) }
                val existing = withContext(io) { ops.activePortForwards() }.firstOrNull { it.remotePort == request.port }
                val forward = existing
                    ?: withContext(io) { ops.startPortForward(request.port, "localhost", preferredLocalPort = request.port) }
                openChannel.send(forward.localUrl)
            }.onFailure { error -> mutableState.update { it.copy(error = error.toUiText()) } }
            mutableState.update { it.copy(isOpening = false) }
        }
    }

    /** «Ahora no»: retira la solicitud sin abrir nada. */
    fun decline() {
        val request = state.value.current ?: return
        handled += request.port
        mutableState.update { it.copy(current = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "rechazar solicitud ${request.port}") {
                val server = repository.server(serverId) ?: throw FileServerMissingException()
                withContext(io) { services.ports(server).dismissPortForwardRequest(request.port) }
            }
        }
    }

    fun errorShown() = mutableState.update { it.copy(error = null) }

    companion object {
        const val POLL_INTERVAL_MILLIS = 5_000L
    }
}

/** Aviso «Claude quiere mostrarte el puerto N» (se dibuja encima de la pantalla del proyecto). */
@Composable
fun PortForwardRequestPrompt(viewModel: PortForwardRequestsViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(viewModel, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { viewModel.pollWhileVisible() }
    }
    LaunchedEffect(viewModel) {
        viewModel.openRequests.collect { url -> openInBrowser(context, url) }
    }
    state.current?.let { request ->
        AlertDialog(
            onDismissRequest = viewModel::decline,
            title = { Text(stringResource(R.string.ports_request_title, request.port.toString())) },
            text = {
                Text(
                    if (request.note.isEmpty()) {
                        stringResource(R.string.ports_request_message, state.serverName)
                    } else {
                        stringResource(R.string.ports_request_message_note, request.note, state.serverName)
                    },
                )
            },
            confirmButton = { TextButton(onClick = viewModel::accept) { Text(stringResource(R.string.ports_open)) } },
            dismissButton = { TextButton(onClick = viewModel::decline) { Text(stringResource(R.string.ports_request_later)) } },
        )
    }
    state.error?.let { error ->
        AlertDialog(
            onDismissRequest = viewModel::errorShown,
            title = { Text(stringResource(R.string.ports_request_failed)) },
            text = { Text(error.asString()) },
            confirmButton = { TextButton(onClick = viewModel::errorShown) { Text(stringResource(R.string.action_close)) } },
        )
    }
}
