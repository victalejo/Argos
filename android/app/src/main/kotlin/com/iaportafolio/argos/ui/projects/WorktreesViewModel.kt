package com.iaportafolio.argos.ui.projects

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.git.GitBranchName
import com.iaportafolio.argos.core.git.GitOperations
import com.iaportafolio.argos.core.git.GitWorktree
import com.iaportafolio.argos.core.git.GitWorktreeListResult
import com.iaportafolio.argos.core.git.GitWorktreeListing
import com.iaportafolio.argos.core.git.GitWorktreeRequest
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
import com.iaportafolio.argos.ui.git.GitUnavailableException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Estado de la lista de worktrees. */
sealed interface WorktreesLoad {
    data object Loading : WorktreesLoad
    data object GitMissing : WorktreesLoad
    data object NotRepository : WorktreesLoad
    data class Loaded(val listing: GitWorktreeListing) : WorktreesLoad
    data class Failed(val message: UiText) : WorktreesLoad
}

/**
 * «Ramas en paralelo» de un proyecto (port de `WorktreesModel` de Apple). La carpeta sigue a la
 * rama hasta que el usuario la cambia; el nombre, grupo y comando se heredan del proyecto del
 * worktree principal (o del proyecto desde el que se abrió).
 */
data class WorktreesUiState(
    val parent: Project? = null,
    val load: WorktreesLoad = WorktreesLoad.Loading,
    val projects: List<Project> = emptyList(),
    val sessions: List<TmuxSession> = emptyList(),
    val createsBranch: Boolean = true,
    val branch: String = "",
    val base: String = "HEAD",
    val path: String = "",
    val pathEdited: Boolean = false,
    val startsAgent: Boolean = true,
    val isWorking: Boolean = false,
    val confirmRemoval: GitWorktree? = null,
    val message: UiText? = null,
) {
    val listing: GitWorktreeListing? get() = (load as? WorktreesLoad.Loaded)?.listing
    val freeBranches: List<String> get() = listing?.freeBranches.orEmpty()
    val baseOptions: List<String> get() = listOf("HEAD") + listing?.branches.orEmpty()

    /** Proyecto de Argos de un worktree (si lo tiene). */
    fun projectFor(worktree: GitWorktree): Project? = projects.firstOrNull { normalized(it.path) == normalized(worktree.path) }

    fun isRunning(worktree: GitWorktree): Boolean = projectFor(worktree)?.let { p -> sessions.any { it.name == p.sessionName } } == true

    val namingParent: Project? get() = listing?.main?.let(::projectFor) ?: parent

    val projectName: String get() = namingParent?.let { worktreeProjectName(it, branch) }.orEmpty()

    val suggestedPath: String get() = if (branch.isEmpty()) "" else listing?.defaultPath(branch).orEmpty()

    val validationError: String?
        get() {
            val listing = listing ?: return null
            return try {
                GitWorktreeRequest.make(listing, branch, createsBranch, base, path)
                null
            } catch (error: GitWorktreeRequest.InvalidException) {
                error.message
            }
        }

    val canCreate: Boolean get() = !isWorking && branch.isNotEmpty() && validationError == null

    companion object {
        /** Nombre del proyecto de un worktree: «app-feat-login» (igual que Apple). */
        fun worktreeProjectName(parent: Project, branch: String) = "${parent.name}-${GitBranchName.projectSlug(branch)}"

        private fun normalized(path: String) = path.trimEnd('/').ifEmpty { "/" }
    }
}

class WorktreesViewModel(
    private val serverId: String,
    private val projectId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val preferences: ProjectPreferencesStore,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(WorktreesUiState())
    val state: StateFlow<WorktreesUiState> = mutableState.asStateFlow()

    init {
        reload()
    }

    private suspend fun service(): SSHServicing {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.service(server)
    }

    private suspend fun git(): GitOperations = service() as? GitOperations ?: throw GitUnavailableException()

    fun reload() {
        viewModelScope.launch { reloadNow() }
    }

    private suspend fun reloadNow() {
        logFailures(ArgosLog.TAG_SSH, "No se pudieron leer los worktrees del proyecto $projectId") {
            val service = service()
            val projects = withContext(io) { service.loadProjects() }
            val sessions = withContext(io) { service.listSessions() }
            val parent = projects.firstOrNull { it.id == projectId } ?: state.value.parent ?: throw FileServerMissingException()
            val listing = withContext(io) { git().gitWorktrees(parent.path) }
            Triple(parent, projects to sessions, listing)
        }.onSuccess { (parent, lists, result) ->
            mutableState.update { state ->
                val load = when (result) {
                    GitWorktreeListResult.GitMissing -> WorktreesLoad.GitMissing
                    GitWorktreeListResult.NotRepository -> WorktreesLoad.NotRepository
                    is GitWorktreeListResult.Loaded -> WorktreesLoad.Loaded(result.listing)
                }
                val next = state.copy(parent = parent, projects = lists.first, sessions = lists.second, load = load)
                if (next.pathEdited) next else next.copy(path = next.suggestedPath)
            }
        }.onFailure { error ->
            mutableState.update { if (it.listing == null) it.copy(load = WorktreesLoad.Failed(error.toUiText())) else it }
        }
    }

    // MARK: - Formulario

    fun onCreatesBranch(value: Boolean) = mutableState.update { state ->
        val branch = if (!value && state.branch !in state.freeBranches) state.freeBranches.firstOrNull().orEmpty() else state.branch
        state.copy(createsBranch = value).withBranch(branch)
    }

    fun onBranch(value: String) = mutableState.update { it.withBranch(value) }

    fun onBase(value: String) = mutableState.update { it.copy(base = value) }

    fun onPath(value: String) = mutableState.update { it.copy(path = value, pathEdited = value != it.suggestedPath) }

    fun onStartsAgent(value: Boolean) = mutableState.update { it.copy(startsAgent = value) }

    private fun WorktreesUiState.withBranch(value: String): WorktreesUiState {
        val next = copy(branch = value)
        return if (pathEdited) next else next.copy(path = next.suggestedPath)
    }

    // MARK: - Crear

    fun create() {
        val state = state.value
        val listing = state.listing ?: return
        val parent = state.namingParent ?: return
        if (!state.canCreate) return
        mutableState.update { it.copy(isWorking = true, message = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo crear el worktree ${state.branch}") {
                val request = GitWorktreeRequest.make(listing, state.branch, state.createsBranch, state.base, state.path)
                val service = service()
                val fresh = withContext(io) { service.loadProjects() }
                val sessions = withContext(io) { service.listSessions() }
                val draft = Project(
                    name = WorktreesUiState.worktreeProjectName(parent, request.branch),
                    group = parent.group,
                    path = request.path,
                    startupCommand = parent.startupCommand,
                )
                // Se valida ANTES de crear nada: un nombre repetido no debe dejar un worktree huérfano.
                ProjectLifecycle.planSave(draft, fresh, sessions)
                val realPath = withContext(io) { git().gitAddWorktree(request) }
                val project = ProjectLifecycle.planSave(draft.copy(path = realPath), fresh, sessions).project
                withContext(io) { service.saveProjects(ProjectLifecycle.upserting(service.loadProjects(), project)) }
                if (state.startsAgent) {
                    ProjectLifecycle.startRequest(project, sessions, preferences.preferences.value.defaultStartupCommand)?.let {
                        withContext(io) { service.startProject(it.sessionName, it.path, it.startupCommand) }
                    }
                }
                project to request.branch
            }.onSuccess { (project, branch) ->
                mutableState.update {
                    it.copy(message = UiText.res(R.string.worktrees_created, project.name, branch), branch = "", path = "", pathEdited = false)
                }
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            reloadNow()
            mutableState.update { it.copy(isWorking = false) }
        }
    }

    // MARK: - Quitar y adoptar

    fun requestRemoval(worktree: GitWorktree) = mutableState.update { it.copy(confirmRemoval = worktree) }

    fun dismissRemoval() = mutableState.update { it.copy(confirmRemoval = null) }

    /** Detiene la sesión de su proyecto, quita el worktree (forzado si tiene cambios) y su proyecto. */
    fun confirmRemoval() {
        val state = state.value
        val worktree = state.confirmRemoval ?: return
        val main = state.listing?.main ?: return
        if (worktree.isMain) return
        val project = state.projectFor(worktree)
        mutableState.update { it.copy(confirmRemoval = null, isWorking = true, message = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo quitar el worktree ${worktree.path}") {
                val service = service()
                if (project != null && state.isRunning(worktree)) withContext(io) { service.stopSession(project.sessionName) }
                withContext(io) { git().gitRemoveWorktree(main.path, worktree.path, force = (worktree.changedCount ?: 0) > 0) }
                if (project != null) {
                    withContext(io) { service.saveProjects(ProjectLifecycle.removing(service.loadProjects(), project.id)) }
                }
            }.onSuccess {
                mutableState.update { it.copy(message = UiText.res(R.string.worktrees_removed, worktree.displayBranch)) }
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            reloadNow()
            mutableState.update { it.copy(isWorking = false) }
        }
    }

    /** Añade como proyecto un worktree que existía sin proyecto (creado fuera de Argos). */
    fun adopt(worktree: GitWorktree) {
        val branch = worktree.branch ?: return
        val parent = state.value.namingParent ?: return
        mutableState.update { it.copy(isWorking = true, message = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_STORE, "No se pudo añadir el worktree ${worktree.path}") {
                val service = service()
                val fresh = withContext(io) { service.loadProjects() }
                val sessions = withContext(io) { service.listSessions() }
                val draft = Project(
                    name = WorktreesUiState.worktreeProjectName(parent, branch),
                    group = parent.group,
                    path = worktree.path,
                    startupCommand = parent.startupCommand,
                )
                val project = ProjectLifecycle.planSave(draft, fresh, sessions).project
                withContext(io) { service.saveProjects(ProjectLifecycle.upserting(fresh, project)) }
                project
            }.onSuccess { project -> mutableState.update { it.copy(message = UiText.res(R.string.worktrees_adopted, project.name)) } }
                .onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            reloadNow()
            mutableState.update { it.copy(isWorking = false) }
        }
    }

    fun messageShown() = mutableState.update { it.copy(message = null) }
}
