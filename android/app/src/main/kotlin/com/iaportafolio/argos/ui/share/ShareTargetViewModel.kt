package com.iaportafolio.argos.ui.share

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectListing
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.AttachmentSource
import com.iaportafolio.argos.data.PickedAttachment
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.terminal.PendingShares
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

/** Un destino de lo compartido: un proyecto (corra o no) o una sesión suelta. */
sealed interface ShareDestination {
    val sessionName: String

    data class ProjectTarget(val project: Project, val isRunning: Boolean) : ShareDestination {
        override val sessionName: String get() = project.sessionName
    }

    data class SessionTarget(val session: TmuxSession) : ShareDestination {
        override val sessionName: String get() = session.name
    }
}

sealed interface ShareLoad {
    data object Idle : ShareLoad

    data object Loading : ShareLoad

    data class Failed(val message: String) : ShareLoad

    /** Proyectos en marcha primero; luego los detenidos y las sesiones sueltas. */
    data class Loaded(val destinations: List<ShareDestination>) : ShareLoad
}

data class ShareTargetUiState(
    val attachments: List<PickedAttachment> = emptyList(),
    val servers: List<Server> = emptyList(),
    val selectedServer: Server? = null,
    val load: ShareLoad = ShareLoad.Idle,
)

/** Navegación de una sola vez tras elegir destino. */
sealed interface ShareEvent {
    data class OpenProject(val serverId: String, val projectId: String) : ShareEvent

    data class OpenSession(val serverId: String, val session: String) : ShareEvent
}

/**
 * «Compartir» → Argos (equivale a soltar archivos sobre el terminal en el Mac): se elige servidor y
 * proyecto, y lo compartido queda en [PendingShares] hasta que el terminal de esa sesión se conecte;
 * entonces se sube y su ruta se teclea en la línea de comandos.
 */
class ShareTargetViewModel(
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val source: AttachmentSource,
    private val pending: PendingShares,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(ShareTargetUiState(servers = repository.servers.value))
    val state: StateFlow<ShareTargetUiState> = mutableState.asStateFlow()

    private val eventChannel = Channel<ShareEvent>(Channel.BUFFERED)
    val events: Flow<ShareEvent> = eventChannel.receiveAsFlow()

    private var loadJob: Job? = null

    init {
        viewModelScope.launch { repository.servers.collect { servers -> mutableState.update { it.copy(servers = servers) } } }
    }

    /** Lo compartido (nombres y tamaños se leen fuera del hilo principal). */
    fun setShared(uris: List<String>) {
        viewModelScope.launch {
            val described = withContext(io) { uris.distinct().map(source::describe) }
            mutableState.update { it.copy(attachments = described) }
        }
    }

    fun selectServer(server: Server) {
        loadJob?.cancel()
        mutableState.update { it.copy(selectedServer = server, load = ShareLoad.Loading) }
        loadJob = viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudieron leer los proyectos de ${server.endpoint} para compartir") {
                val service = services.service(server)
                withContext(io) { service.loadProjects() to service.listSessions() }
            }.onSuccess { (projects, sessions) ->
                mutableState.update { it.copy(load = ShareLoad.Loaded(destinations(projects, sessions))) }
            }.onFailure { error -> mutableState.update { it.copy(load = ShareLoad.Failed(error.userMessage)) } }
        }
    }

    fun backToServers() {
        loadJob?.cancel()
        mutableState.update { it.copy(selectedServer = null, load = ShareLoad.Idle) }
    }

    fun choose(destination: ShareDestination) {
        val current = state.value
        val server = current.selectedServer ?: return
        if (current.attachments.isEmpty()) return
        pending.put(server.id, destination.sessionName, current.attachments)
        val event = when (destination) {
            is ShareDestination.ProjectTarget -> ShareEvent.OpenProject(server.id, destination.project.id)
            is ShareDestination.SessionTarget -> ShareEvent.OpenSession(server.id, destination.session.name)
        }
        eventChannel.trySend(event)
    }

    companion object {
        fun destinations(projects: List<Project>, sessions: List<TmuxSession>): List<ShareDestination> {
            val listing = ProjectListing.build(projects, sessions)
            val byProject = listing.entries.map { ShareDestination.ProjectTarget(it.project, it.isRunning) }
            val running = byProject.filter { it.isRunning }
            val stopped = byProject.filterNot { it.isRunning }
            return running + listing.looseSessions.map(ShareDestination::SessionTarget) + stopped
        }
    }
}
