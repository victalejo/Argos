package com.iaportafolio.argos.ui.project

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectLifecycle
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ProjectPreferencesStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import com.iaportafolio.argos.ui.files.FileServerMissingException
import com.iaportafolio.argos.ui.files.toFilesUiText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Pestañas del detalle de un proyecto (como el selector de `ProjectScreen` de iOS). */
enum class ProjectTab { TERMINAL, FILES, AGENTS }

sealed interface ProjectLoad {
    data object Loading : ProjectLoad

    data class Failed(val message: UiText) : ProjectLoad

    /** El proyecto ya no está en `projects.json` (quitado desde otro cliente). */
    data object Missing : ProjectLoad

    /** [isRunning] = su sesión tmux existe: el terminal puede engancharse. */
    data class Loaded(val project: Project, val isRunning: Boolean) : ProjectLoad
}

data class ProjectUiState(
    val serverName: String = "",
    val load: ProjectLoad = ProjectLoad.Loading,
    val tab: ProjectTab = ProjectTab.TERMINAL,
    val isStarting: Boolean = false,
    val message: UiText? = null,
) {
    val project: Project? get() = (load as? ProjectLoad.Loaded)?.project
}

/**
 * Detalle de un proyecto (port de `ProjectScreen` de iOS): elige pestaña y sabe si su sesión
 * corre. Si está detenido, el terminal ofrece arrancarlo con `ProjectLifecycle.startRequest`.
 */
class ProjectViewModel(
    private val serverId: String,
    private val projectId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val preferences: ProjectPreferencesStore,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(ProjectUiState(serverName = repository.server(serverId)?.name.orEmpty()))
    val state: StateFlow<ProjectUiState> = mutableState.asStateFlow()

    private var loadJob: Job? = null

    /** Sesiones de la última lectura (para decidir si hay que arrancar). */
    private var sessions: List<TmuxSession> = emptyList()

    init {
        reload()
    }

    fun selectTab(tab: ProjectTab) = mutableState.update { it.copy(tab = tab) }

    /** Relee el proyecto y si su sesión corre (al abrir y al volver a primer plano). */
    fun reload() {
        loadJob?.cancel()
        if (state.value.load !is ProjectLoad.Loaded) mutableState.update { it.copy(load = ProjectLoad.Loading) }
        loadJob = viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo leer el proyecto $projectId del servidor $serverId") {
                val server = repository.server(serverId) ?: throw FileServerMissingException()
                val service = services.service(server)
                val projects = withContext(io) { service.loadProjects() }
                sessions = withContext(io) { service.listSessions() }
                projects.firstOrNull { it.id == projectId }
            }.onSuccess { project ->
                val load = if (project == null) {
                    ProjectLoad.Missing
                } else {
                    ProjectLoad.Loaded(project, sessions.any { it.name == project.sessionName })
                }
                mutableState.update { it.copy(load = load) }
            }.onFailure { error ->
                // Con el proyecto ya visible, un fallo de red no lo oculta: se avisa.
                mutableState.update { state ->
                    if (state.load is ProjectLoad.Loaded) {
                        state.copy(message = error.toFilesUiText())
                    } else {
                        state.copy(load = ProjectLoad.Failed(error.toFilesUiText()))
                    }
                }
            }
        }
    }

    /** Arranca el proyecto detenido (sesión en su carpeta + comando de arranque). */
    fun start() {
        val project = state.value.project ?: return
        if (state.value.isStarting) return
        mutableState.update { it.copy(isStarting = true) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo arrancar el proyecto $projectId") {
                val server = repository.server(serverId) ?: throw FileServerMissingException()
                val service = services.service(server)
                val current = withContext(io) { service.listSessions() }
                ProjectLifecycle.startRequest(project, current, preferences.preferences.value.defaultStartupCommand)?.let {
                    withContext(io) { service.startProject(it.sessionName, it.path, it.startupCommand) }
                }
            }.onSuccess {
                mutableState.update { it.copy(load = ProjectLoad.Loaded(project, isRunning = true)) }
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            mutableState.update { it.copy(isStarting = false) }
        }
    }

    fun messageShown() = mutableState.update { it.copy(message = null) }

    companion object {
        /** Recurso del título de cada pestaña (UI y accesibilidad). */
        fun titleOf(tab: ProjectTab): Int = when (tab) {
            ProjectTab.TERMINAL -> R.string.project_tab_terminal
            ProjectTab.FILES -> R.string.project_tab_files
            ProjectTab.AGENTS -> R.string.project_tab_agents
        }
    }
}
