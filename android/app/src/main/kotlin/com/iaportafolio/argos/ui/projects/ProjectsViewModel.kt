package com.iaportafolio.argos.ui.projects

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.git.GitCommandException
import com.iaportafolio.argos.core.git.GitOperations
import com.iaportafolio.argos.core.github.GitHubOperations
import com.iaportafolio.argos.core.github.GitHubRepositoriesResult
import com.iaportafolio.argos.core.github.GitHubRepository
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectConfirmation
import com.iaportafolio.argos.core.projects.ProjectEntry
import com.iaportafolio.argos.core.projects.ProjectLifecycle
import com.iaportafolio.argos.core.projects.ProjectStatusFilter
import com.iaportafolio.argos.core.tmux.SessionNameValidator
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ProjectPreferencesStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import com.iaportafolio.argos.ui.sessions.ConnectStep
import com.iaportafolio.argos.ui.sessions.SessionDialog
import com.iaportafolio.argos.ui.sessions.SessionDialogActions
import com.iaportafolio.argos.ui.sessions.SessionsLoad
import com.iaportafolio.argos.ui.sessions.ensureTmuxEnvironment
import com.iaportafolio.argos.ui.sessions.loadFailure
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
import java.time.Instant

/**
 * Proyectos y sesiones tmux de UN servidor (port de `SessionsViewModel` +
 * `SessionsViewModel+Projects` de Apple). Al conectar asegura tmux y luego lista sesiones y
 * `projects.json`. Toda decisión de proyectos sale de `ProjectLifecycle`/`ProjectListing`
 * (core); aquí solo se orquesta con [SSHServicing] siguiendo leer-modificar-escribir sobre la
 * versión ACTUAL del servidor (otro cliente pudo cambiarla).
 */
class ProjectsViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val hostKeys: HostKeyTrustStore,
    private val preferences: ProjectPreferencesStore,
    private val io: CoroutineDispatcher,
) : ViewModel(), ProjectsActions, SessionDialogActions {

    private val mutableState = MutableStateFlow(
        ProjectsUiState(
            serverId = serverId,
            serverName = repository.server(serverId)?.name.orEmpty(),
            preferences = preferences.preferences.value,
        ),
    )
    val state: StateFlow<ProjectsUiState> = mutableState.asStateFlow()

    private val eventChannel = Channel<ProjectsEvent>(Channel.BUFFERED)

    /** Navegación de una sola vez (abrir proyecto / sesión). */
    val events: Flow<ProjectsEvent> = eventChannel.receiveAsFlow()

    private var loadJob: Job? = null

    init {
        viewModelScope.launch {
            repository.servers.collect { servers ->
                servers.firstOrNull { it.id == serverId }?.let { server ->
                    mutableState.update { it.copy(serverName = server.name) }
                }
            }
        }
        viewModelScope.launch {
            preferences.preferences.collect { prefs -> mutableState.update { it.copy(preferences = prefs) } }
        }
        load()
    }

    // MARK: - Conexión y listado

    /** Conecta desde cero (arranque de tmux incluido). Cancela una carga anterior. */
    override fun load() {
        loadJob?.cancel()
        mutableState.update { it.copy(load = SessionsLoad.Connecting(ConnectStep.VERIFYING), isRefreshing = false) }
        loadJob = viewModelScope.launch {
            val server = repository.server(serverId)
                ?: return@launch mutableState.update { it.copy(load = SessionsLoad.ServerMissing, sessions = emptyList()) }
            logFailures(ArgosLog.TAG_SSH, "No se pudo cargar las sesiones de ${server.endpoint}") {
                val service = services.service(server)
                ensureTmuxEnvironment(service, io, ::step)
                step(ConnectStep.LOADING)
                withContext(io) { service.listSessions() }
            }.onSuccess { sessions ->
                mutableState.update { it.copy(load = SessionsLoad.Loaded, sessions = sessions) }
                reloadProjects(server)
            }.onFailure { error -> mutableState.update { it.copy(load = loadFailure(error), sessions = emptyList()) } }
        }
    }

    /** Pull-to-refresh: con la lista visible solo re-lista; si no, reconecta. */
    override fun refresh() {
        if (state.value.load != SessionsLoad.Loaded) return load()
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

    private fun step(step: ConnectStep) = mutableState.update { it.copy(load = SessionsLoad.Connecting(step)) }

    /**
     * Re-lista sesiones y proyectos sin repetir el arranque. Un fallo con la lista visible se
     * avisa sin borrarla (salvo huella cambiada o tmux desaparecido, que cambian de pantalla).
     */
    private suspend fun relist() {
        val server = currentServer() ?: return
        logFailures(ArgosLog.TAG_SSH, "No se pudo re-listar las sesiones de ${server.endpoint}") {
            withContext(io) { services.service(server).listSessions() }
        }.onSuccess { sessions ->
            mutableState.update { it.copy(load = SessionsLoad.Loaded, sessions = sessions) }
            reloadProjects(server)
        }.onFailure { error ->
            when (val failure = loadFailure(error)) {
                is SessionsLoad.Failed -> mutableState.update { it.copy(message = error.toUiText()) }
                else -> mutableState.update { it.copy(load = failure, sessions = emptyList()) }
            }
        }
    }

    /** Relee `projects.json`. Un fallo no tumba la lista de sesiones: se muestra aparte. */
    private suspend fun reloadProjects(server: Server) {
        logFailures(ArgosLog.TAG_STORE, "No se pudo leer projects.json de ${server.endpoint}") {
            withContext(io) { services.service(server).loadProjects() }
        }.onSuccess { projects ->
            mutableState.update { it.copy(projects = projects, projectsError = null) }
            reloadGitSummaries(server, projects)
        }.onFailure { error -> mutableState.update { it.copy(projectsError = error.userMessage) } }
    }

    /**
     * Resumen git de todos los proyectos en UN comando (port de `refreshGitSummaries` de Apple).
     * Se relee al cargar, al volver a la pantalla y con pull-to-refresh. Es informativo: un fallo
     * conserva lo último y no se avisa.
     */
    private suspend fun reloadGitSummaries(server: Server, projects: List<Project>) {
        val paths = projects.map { it.path }.distinct()
        if (paths.isEmpty()) return mutableState.update { it.copy(gitSummaries = emptyMap()) }
        logFailures(ArgosLog.TAG_SSH, "No se pudo leer el resumen git de ${server.endpoint}") {
            val git = services.service(server) as? GitOperations ?: return
            withContext(io) { git.gitSummaries(paths) }
        }.onSuccess { summaries -> mutableState.update { it.copy(gitSummaries = summaries) } }
    }

    private fun currentServer(): Server? = repository.server(serverId)
        ?: run {
            mutableState.update { it.copy(load = SessionsLoad.ServerMissing, dialog = null, sessionDialog = null) }
            null
        }

    /**
     * Lee-modifica-escribe sobre la versión ACTUAL de `projects.json` (port de `mutateProjects`).
     */
    private suspend fun mutateProjects(service: SSHServicing, transform: (List<Project>) -> List<Project>) {
        val fresh = withContext(io) { service.loadProjects() }
        val next = transform(fresh)
        withContext(io) { service.saveProjects(next) }
        mutableState.update { it.copy(projects = next, projectsError = null) }
    }

    // MARK: - Filtro y grupos

    override fun setFilter(filter: ProjectStatusFilter) = preferences.setStatusFilter(filter)

    override fun toggleGroup(group: String) = preferences.toggleCollapsed(serverId, group)

    // MARK: - Abrir / detener / quitar

    /** Abre el proyecto: si no corre, crea su sesión en la carpeta con su comando de arranque. */
    override fun openProject(entry: ProjectEntry) {
        if (state.value.busyProjectId != null) return
        val request = ProjectLifecycle.startRequest(entry.project, state.value.sessions, state.value.preferences.defaultStartupCommand)
            ?: return emit(ProjectsEvent.OpenProject(entry.project.id))
        val server = currentServer() ?: return
        mutableState.update { it.copy(busyProjectId = entry.project.id) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo abrir el proyecto en ${server.endpoint}") {
                val service = services.service(server)
                withContext(io) { service.startProject(request.sessionName, request.path, request.startupCommand) }
            }.onSuccess {
                relist()
                emit(ProjectsEvent.OpenProject(entry.project.id))
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            mutableState.update { it.copy(busyProjectId = null) }
        }
    }

    override fun openSession(session: TmuxSession) = emit(ProjectsEvent.OpenSession(session.name))

    override fun openWorktrees(project: Project) = emit(ProjectsEvent.OpenWorktrees(project.id))

    override fun requestStop(project: Project) = confirm(ProjectConfirmation.Stop(serverOrSelf(), project))

    override fun requestRemove(project: Project) = confirm(ProjectConfirmation.Remove(serverOrSelf(), project))

    private fun confirm(confirmation: ProjectConfirmation) =
        mutableState.update { it.copy(dialog = ProjectsDialog.Confirm(confirmation)) }

    /** Servidor para los textos de confirmación (siempre existe mientras la lista está visible). */
    private fun serverOrSelf(): Server = repository.server(serverId) ?: Server(id = serverId, name = "", host = "", username = "")

    override fun confirmProjectAction() {
        val dialog = state.value.dialog as? ProjectsDialog.Confirm ?: return
        if (dialog.isSubmitting) return
        val server = currentServer() ?: return
        mutableState.update { it.copy(dialog = dialog.copy(isSubmitting = true)) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo completar «${dialog.confirmation.actionLabel}» en ${server.endpoint}") {
                val service = services.service(server)
                when (val confirmation = dialog.confirmation) {
                    is ProjectConfirmation.Stop -> withContext(io) { service.stopSession(confirmation.project.sessionName) }
                    is ProjectConfirmation.Remove -> mutateProjects(service) { ProjectLifecycle.removing(it, confirmation.project.id) }
                    is ProjectConfirmation.StopBackground -> confirmation.projects.forEach {
                        withContext(io) { service.stopSession(it.sessionName) }
                    }
                }
            }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
            mutableState.update { it.copy(dialog = null) }
            relist()
        }
    }

    // MARK: - Formulario de proyecto

    override fun openNewProject() = openForm(
        ProjectFormState.forNew(state.value.existingGroups, state.value.preferences.defaultStartupCommand),
    )

    override fun openEditProject(project: Project) = openForm(
        ProjectFormState.forEdit(project, state.value.existingGroups, state.value.preferences.defaultStartupCommand),
    )

    /** «Convertir en proyecto»: propone la carpeta en la que está el primer panel de la sesión. */
    override fun openConvert(session: TmuxSession) {
        openForm(ProjectFormState.forConvert(session.name, state.value.existingGroups, state.value.preferences.defaultStartupCommand))
        val server = currentServer() ?: return
        viewModelScope.launch {
            val found = logFailures(ArgosLog.TAG_SSH, "No se pudo leer la carpeta de la sesión en ${server.endpoint}") {
                withContext(io) { services.service(server).sessionFirstPanePaths() }[session.name]
            }.getOrNull()
            updateForm { form -> form.copy(isPrefilling = false, path = form.path.ifEmpty { found.orEmpty() }) }
        }
    }

    private fun openForm(form: ProjectFormState) = mutableState.update { it.copy(dialog = ProjectsDialog.Form(form)) }

    override fun onFormName(name: String) = updateForm { it.copy(name = name, error = null) }

    override fun onFormGroup(group: String) = updateForm { it.copy(group = group, error = null) }

    override fun onFormPath(path: String) = updateForm { it.copy(path = path, error = null) }

    /** Carpeta elegida con el selector visual (propone el nombre si aún está vacío). */
    override fun onFolderPicked(path: String) = updateForm { form ->
        form.copy(path = path, name = form.name.ifBlank { ProjectFormState.folderName(path) }, error = null)
    }

    override fun onFormCommand(choice: StartupChoice) = updateForm { it.copy(command = choice, error = null) }

    override fun onFormCustomCommand(command: String) = updateForm { it.copy(customCommand = command, error = null) }

    // MARK: - Clonar de GitHub

    /** Cambia el origen del proyecto nuevo; al pasar a clonar, carga tus repositorios (una vez). */
    override fun onFormClone(enabled: Boolean) {
        updateForm { form -> form.copy(clone = if (enabled) form.clone ?: CloneFormState() else null, error = null) }
        if (enabled) loadCloneRepositories(force = false)
    }

    override fun onCloneRepository(value: String) = updateClone { it.withRepository(value) }

    override fun onCloneChoose(repository: GitHubRepository) = updateClone { it.choosing(repository) }

    override fun onCloneParent(value: String) = updateClone { it.copy(parent = value) }

    override fun onCloneFolder(value: String) = updateClone { it.withFolder(value) }

    override fun retryCloneRepositories() = loadCloneRepositories(force = true)

    /** Aplica un cambio al clonado; el nombre sigue a la carpeta mientras el usuario no lo cambie. */
    private fun updateClone(change: (CloneFormState) -> CloneFormState) = updateForm { form ->
        val clone = form.clone ?: return@updateForm form
        val next = change(clone)
        val followsFolder = form.name.isBlank() || form.name == clone.folder
        form.copy(clone = next, name = if (followsFolder) next.folder else form.name, error = null)
    }

    private fun loadCloneRepositories(force: Boolean) {
        val current = (state.value.dialog as? ProjectsDialog.Form)?.form?.clone ?: return
        if (!force && current.repositories != CloneRepositories.Idle) return
        val server = currentServer() ?: return
        updateClone { it.copy(repositories = CloneRepositories.Loading) }
        viewModelScope.launch {
            val loaded = logFailures(ArgosLog.TAG_SSH, "No se pudo listar los repos de GitHub en ${server.endpoint}") {
                val gitHub = services.service(server) as? GitHubOperations ?: return@logFailures CloneRepositories.GhMissing
                when (val result = withContext(io) { gitHub.gitHubRepositories() }) {
                    GitHubRepositoriesResult.GhMissing -> CloneRepositories.GhMissing
                    GitHubRepositoriesResult.NotAuthenticated -> CloneRepositories.NotAuthenticated
                    is GitHubRepositoriesResult.Failed -> CloneRepositories.Failed(result.message)
                    is GitHubRepositoriesResult.Loaded ->
                        CloneRepositories.Loaded(result.repositories.sortedByDescending { it.updatedAt ?: Instant.MIN })
                }
            }.getOrElse { CloneRepositories.Failed(it.userMessage) }
            updateClone { it.copy(repositories = loaded) }
        }
    }

    /** Clona si hace falta (una sola vez) y devuelve el formulario con la carpeta clonada. */
    private suspend fun clonedForm(server: Server, form: ProjectFormState): ProjectFormState {
        val clone = form.clone ?: return form
        val path = clone.clonedPath ?: run {
            val gitHub = services.service(server) as? GitHubOperations
                ?: throw GitCommandException("Esta conexión no admite GitHub.")
            withContext(io) { gitHub.gitHubClone(clone.request()) }.also { cloned ->
                updateClone { it.copy(clonedPath = cloned) }
            }
        }
        return form.copy(path = path)
    }

    /** Valida con `ProjectLifecycle.planSave` sobre los datos ACTUALES y guarda. */
    override fun submitForm() {
        val form = (state.value.dialog as? ProjectsDialog.Form)?.form ?: return
        if (!form.canSubmit) return
        val server = currentServer() ?: return
        updateForm { it.copy(isSubmitting = true, error = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_STORE, "No se pudo guardar el proyecto en ${server.endpoint}") {
                // Al clonar, la carpeta del proyecto es la que acaba de crear `gh repo clone`.
                val saved = clonedForm(server, form)
                val service = services.service(server)
                val sessions = withContext(io) { service.listSessions() }
                val fresh = withContext(io) { service.loadProjects() }
                val plan = ProjectLifecycle.planSave(saved.toProject(), fresh, sessions, saved.adoptedSession)
                plan.rename?.let { withContext(io) { service.renameSession(it.from, it.to) } }
                mutateProjects(service) { ProjectLifecycle.upserting(it, plan.project) }
            }.onSuccess {
                mutableState.update { it.copy(dialog = null) }
                relist()
            }.onFailure { error -> updateForm { it.copy(isSubmitting = false, error = error.userMessage) } }
        }
    }

    private fun updateForm(change: (ProjectFormState) -> ProjectFormState) = mutableState.update { state ->
        val dialog = state.dialog as? ProjectsDialog.Form
        if (dialog == null) state else state.copy(dialog = ProjectsDialog.Form(change(dialog.form)))
    }

    // MARK: - Importar sesiones sueltas

    override fun openImport() {
        val server = currentServer() ?: return
        mutableState.update { it.copy(dialog = ProjectsDialog.Import(ImportState())) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo leer las carpetas de las sesiones en ${server.endpoint}") {
                withContext(io) { services.service(server).sessionFirstPanePaths() }
            }.onSuccess { paths ->
                val current = state.value
                val candidates = ProjectLifecycle.importCandidates(current.projects, current.sessions, paths)
                updateImport { ImportState(isLoading = false, candidates = candidates, selected = candidates.mapTo(HashSet()) { it.id }) }
            }.onFailure { error -> updateImport { it.copy(isLoading = false, error = error.userMessage) } }
        }
    }

    override fun toggleImportCandidate(projectId: String) = updateImport { import ->
        import.copy(selected = if (projectId in import.selected) import.selected - projectId else import.selected + projectId)
    }

    override fun confirmImport() {
        val import = (state.value.dialog as? ProjectsDialog.Import)?.state ?: return
        if (!import.canImport) return
        val server = currentServer() ?: return
        val chosen = import.candidates.filter { it.id in import.selected }
        updateImport { it.copy(isImporting = true, error = null) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_STORE, "No se pudo importar proyectos en ${server.endpoint}") {
                mutateProjects(services.service(server)) { ProjectLifecycle.importing(it, chosen) }
            }.onSuccess {
                mutableState.update { it.copy(dialog = null) }
                relist()
            }.onFailure { error -> updateImport { it.copy(isImporting = false, error = error.userMessage) } }
        }
    }

    private fun updateImport(change: (ImportState) -> ImportState) = mutableState.update { state ->
        val dialog = state.dialog as? ProjectsDialog.Import
        if (dialog == null) state else state.copy(dialog = ProjectsDialog.Import(change(dialog.state)))
    }

    /** Cierra el diálogo de proyecto salvo que haya un envío en curso. */
    override fun dismissProjectDialog() = mutableState.update { state ->
        val busy = when (val dialog = state.dialog) {
            is ProjectsDialog.Confirm -> dialog.isSubmitting
            is ProjectsDialog.Form -> dialog.form.isSubmitting
            is ProjectsDialog.Import -> dialog.state.isImporting
            null -> false
        }
        if (busy) state else state.copy(dialog = null)
    }

    // MARK: - Sesiones sueltas (crear / renombrar / cerrar)

    override fun openCreateSession() = mutableState.update { it.copy(sessionDialog = SessionDialog.Create()) }

    override fun openRenameSession(session: TmuxSession) =
        mutableState.update { it.copy(sessionDialog = SessionDialog.Rename(session, text = session.name)) }

    override fun requestKillSession(session: TmuxSession) =
        mutableState.update { it.copy(sessionDialog = SessionDialog.ConfirmKill(session)) }

    override fun dismissDialog() = mutableState.update { state ->
        val submitting = (state.sessionDialog as? SessionDialog.NameInput)?.isSubmitting == true
        if (submitting) state else state.copy(sessionDialog = null)
    }

    override fun onDialogTextChange(text: String) = mutableState.update { state ->
        val error = SessionNameValidator.liveValidationMessage(text)
        when (val dialog = state.sessionDialog) {
            is SessionDialog.Create -> state.copy(sessionDialog = dialog.copy(text = text, error = error))
            is SessionDialog.Rename -> state.copy(sessionDialog = dialog.copy(text = text, error = error))
            is SessionDialog.ConfirmKill, null -> state
        }
    }

    /** Crear (y abrir) o renombrar con el nombre tecleado. Los errores van dentro del diálogo. */
    override fun submitDialog() {
        val dialog = state.value.sessionDialog as? SessionDialog.NameInput ?: return
        if (dialog.isSubmitting) return
        val name = try {
            SessionNameValidator.validate(dialog.text)
        } catch (invalid: SessionNameValidator.ValidationError) {
            return updateNameDialog { it.withError(invalid.userMessage) }
        }
        if (dialog is SessionDialog.Rename && name == dialog.session.name) {
            mutableState.update { it.copy(sessionDialog = null) }
            return
        }
        val server = currentServer() ?: return
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
                mutableState.update { it.copy(sessionDialog = null) }
                relist()
                if (dialog is SessionDialog.Create) emit(ProjectsEvent.OpenSession(name))
            }.onFailure { error -> updateNameDialog { it.submitting(false).withError(error.userMessage) } }
        }
    }

    override fun confirmKill() {
        val session = (state.value.sessionDialog as? SessionDialog.ConfirmKill)?.session ?: return
        mutableState.update { it.copy(sessionDialog = null) }
        val server = currentServer() ?: return
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo cerrar una sesión en ${server.endpoint}") {
                val service = services.service(server)
                withContext(io) { service.killSession(session.name) }
            }.onSuccess { relist() }
                .onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
        }
    }

    private fun updateNameDialog(change: (SessionDialog.NameInput) -> SessionDialog.NameInput) =
        mutableState.update { state ->
            val dialog = state.sessionDialog as? SessionDialog.NameInput
            if (dialog == null) state else state.copy(sessionDialog = change(dialog))
        }

    private fun SessionDialog.NameInput.withError(error: String?): SessionDialog.NameInput = when (this) {
        is SessionDialog.Create -> copy(error = error)
        is SessionDialog.Rename -> copy(error = error)
    }

    private fun SessionDialog.NameInput.submitting(value: Boolean): SessionDialog.NameInput = when (this) {
        is SessionDialog.Create -> copy(isSubmitting = value)
        is SessionDialog.Rename -> copy(isSubmitting = value)
    }

    // MARK: - Varios

    override fun messageShown() = mutableState.update { it.copy(message = null) }

    private fun emit(event: ProjectsEvent) {
        eventChannel.trySend(event)
    }
}

/** Acciones de la pantalla de proyectos. */
interface ProjectsActions {
    fun load()
    fun refresh()
    fun forgetHostKeyAndRetry()
    fun messageShown()
    fun setFilter(filter: ProjectStatusFilter)
    fun toggleGroup(group: String)
    fun openProject(entry: ProjectEntry)
    fun openSession(session: TmuxSession)
    fun openWorktrees(project: Project)
    fun requestStop(project: Project)
    fun requestRemove(project: Project)
    fun confirmProjectAction()
    fun openNewProject()
    fun onFormClone(enabled: Boolean)
    fun onCloneRepository(value: String)
    fun onCloneChoose(repository: GitHubRepository)
    fun onCloneParent(value: String)
    fun onCloneFolder(value: String)
    fun retryCloneRepositories()
    fun openEditProject(project: Project)
    fun openConvert(session: TmuxSession)
    fun onFormName(name: String)
    fun onFormGroup(group: String)
    fun onFormPath(path: String)
    fun onFolderPicked(path: String)
    fun onFormCommand(choice: StartupChoice)
    fun onFormCustomCommand(command: String)
    fun submitForm()
    fun openImport()
    fun toggleImportCandidate(projectId: String)
    fun confirmImport()
    fun dismissProjectDialog()
    fun openCreateSession()
    fun openRenameSession(session: TmuxSession)
    fun requestKillSession(session: TmuxSession)
}
