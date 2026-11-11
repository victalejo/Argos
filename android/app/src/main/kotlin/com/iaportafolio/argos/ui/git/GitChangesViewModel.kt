package com.iaportafolio.argos.ui.git

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.git.CommitMessageSuggestion
import com.iaportafolio.argos.core.git.GitFileChange
import com.iaportafolio.argos.core.git.GitOperations
import com.iaportafolio.argos.core.git.GitRepositoryStatus
import com.iaportafolio.argos.core.git.GitStatusResult
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ClaudeTokenStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.agents.SecretRedactor
import com.iaportafolio.argos.ui.agents.agentExec
import com.iaportafolio.argos.ui.agents.agentFailures
import com.iaportafolio.argos.ui.agents.toAgentUiText
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import com.iaportafolio.argos.ui.files.FileServerMissingException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** El servicio del servidor no implementa [GitOperations] (implementación antigua o doble). */
class GitUnavailableException : Exception("La conexión no admite git.")

/** El mismo servicio de [ServiceProvider] (una conexión por servidor) visto como [GitOperations]. */
internal suspend fun ServiceProvider.git(server: Server): GitOperations =
    service(server) as? GitOperations ?: throw GitUnavailableException()

/**
 * Panel «Cambios» de UN proyecto (port de `GitChangesModel` de Apple): estado git, archivo
 * seleccionado y su diff, qué archivos entran en el commit y las operaciones (descartar, commit,
 * push, pull). git corre en el servidor; mientras la pantalla está visible se refresca cada
 * [POLL_INTERVAL_MILLIS] porque el agente puede estar editando archivos a la vez.
 */
class GitChangesViewModel(
    private val serverId: String,
    private val path: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
    /** Token de Claude para «Sugerir mensaje» (`null`: credencial de `claude login` del servidor). */
    private val claudeTokens: ClaudeTokenStore? = null,
    /** Tras un push correcto (raíz del repo): para vigilar su CI y avisar al terminar. */
    private val onPushed: (root: String) -> Unit = {},
) : ViewModel() {

    private val mutableState = MutableStateFlow(GitChangesUiState(path = path))
    val state: StateFlow<GitChangesUiState> = mutableState.asStateFlow()

    private var refreshJob: Job? = null
    private var diffJob: Job? = null
    private var pollJob: Job? = null

    init {
        refresh()
    }

    private suspend fun git(): GitOperations {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.git(server)
    }

    // MARK: - Carga

    /**
     * Vuelve a leer el estado. [reloadDiff]: recarga también el diff seleccionado (el refresco
     * automático no lo hace, salvo que cambie el estado del archivo). Ignorado si ya hay uno.
     */
    fun refresh(reloadDiff: Boolean = true) {
        if (refreshJob?.isActive == true) return
        refreshJob = viewModelScope.launch { refreshNow(reloadDiff) }
    }

    private suspend fun refreshNow(reloadDiff: Boolean) {
        val previous = state.value.selectedChange
        logFailures(ArgosLog.TAG_SSH, "git status de $path") {
            withContext(io) { git().gitStatus(path) }
        }.onSuccess { result ->
            mutableState.update { state ->
                when (result) {
                    GitStatusResult.GitMissing -> state.copy(load = GitPanelLoad.GitMissing)
                    GitStatusResult.NotRepository -> state.copy(load = GitPanelLoad.NotRepository)
                    is GitStatusResult.Repository -> state.applying(result.status)
                }
            }
        }.onFailure { error ->
            // Un fallo del refresco automático no borra lo que ya se ve.
            mutableState.update { if (it.status == null) it.copy(load = GitPanelLoad.Failed(error.toGitUiText())) else it }
            return
        }
        val current = state.value.selectedChange
        when {
            current == null -> mutableState.update { it.copy(selectedPath = null, diff = GitDiffLoad.None) }
            reloadDiff || current != previous -> loadDiff()
        }
    }

    private fun GitChangesUiState.applying(status: GitRepositoryStatus): GitChangesUiState {
        val paths = status.changes.mapTo(HashSet()) { it.path }
        return copy(load = GitPanelLoad.Loaded(status), excludedPaths = excludedPaths intersect paths)
    }

    /** Refresco periódico mientras la pantalla esté en primer plano. */
    fun startPolling() {
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            while (true) {
                delay(POLL_INTERVAL_MILLIS)
                if (state.value.operation == null) refresh(reloadDiff = false)
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    // MARK: - Selección y diff

    fun select(path: String?) {
        if (path == state.value.selectedPath) return
        mutableState.update { it.copy(selectedPath = path) }
        viewModelScope.launch { loadDiff() }
    }

    private suspend fun loadDiff() {
        diffJob?.cancel()
        val state = state.value
        val change = state.selectedChange
        val status = state.status
        if (change == null || status == null) {
            mutableState.update { it.copy(diff = GitDiffLoad.None) }
            return
        }
        if (state.diff !is GitDiffLoad.Loaded) mutableState.update { it.copy(diff = GitDiffLoad.Loading) }
        val job = viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "git diff de ${change.path}") {
                withContext(io) { git().gitDiff(status.root, change, status.branch.hasCommits) }
            }.onSuccess { diff -> mutableState.update { it.copy(diff = GitDiffLoad.Loaded(diff)) } }
                .onFailure { error -> mutableState.update { it.copy(diff = GitDiffLoad.Failed(error.toGitUiText())) } }
        }
        diffJob = job
        job.join()
    }

    // MARK: - Selección para el commit

    fun setIncluded(change: GitFileChange, included: Boolean) = mutableState.update {
        it.copy(excludedPaths = if (included) it.excludedPaths - change.path else it.excludedPaths + change.path)
    }

    fun setAllIncluded(included: Boolean) = mutableState.update { state ->
        state.copy(excludedPaths = if (included) emptySet() else state.changes.mapTo(HashSet()) { it.path })
    }

    fun onCommitMessage(message: String) = mutableState.update { it.copy(commitMessage = message) }

    // MARK: - Operaciones

    fun requestDiscard(change: GitFileChange) = mutableState.update { it.copy(confirmDiscard = change) }

    fun dismissDiscard() = mutableState.update { it.copy(confirmDiscard = null) }

    fun confirmDiscard() {
        val state = state.value
        val change = state.confirmDiscard ?: return
        mutableState.update { it.copy(confirmDiscard = null) }
        val status = state.status ?: return
        if (!status.branch.hasCommits && !change.isUntracked) {
            mutableState.update { it.copy(message = UiText.res(R.string.git_discard_no_commits)) }
            return
        }
        perform(GitOperation.Discard(change.path)) {
            git().gitDiscard(status.root, change)
            null
        }
    }

    fun commit() {
        val state = state.value
        val status = state.status
        if (!state.canCommit || status == null) return
        val message = state.commitMessage.trim()
        val included = state.includedChanges
        perform(GitOperation.Commit, onSuccess = { it.copy(commitMessage = "") }) {
            val output = git().gitCommit(status.root, message, included)
            firstLine(output)?.let(UiText::Plain) ?: UiText.res(R.string.git_commit_done)
        }
    }

    fun push() {
        val state = state.value
        val status = state.status
        if (!state.canPush || status == null) return
        perform(GitOperation.Push, onSuccess = { it.also { onPushed(status.root) } }) {
            git().gitPush(status.root, hasUpstream = status.branch.upstream != null)
            UiText.res(R.string.git_push_done, status.branch.upstream ?: "origin")
        }
    }

    fun pull() {
        val state = state.value
        val status = state.status
        if (!state.canPull || status == null) return
        perform(GitOperation.Pull) {
            firstLine(git().gitPull(status.root))?.let(UiText::Plain) ?: UiText.res(R.string.git_pull_done)
        }
    }

    /**
     * «Sugerir mensaje»: Claude Code, en el servidor, propone el mensaje a partir del diff de los
     * archivos marcados y los últimos mensajes del repo. Si falla, no toca lo escrito.
     */
    fun suggestCommitMessage() {
        val state = state.value
        val status = state.status
        if (!state.canSuggestMessage || status == null) return
        val included = state.includedChanges
        mutableState.update { it.copy(operation = GitOperation.Suggest) }
        viewModelScope.launch {
            var token: String? = null
            agentFailures("sugerir mensaje de commit") {
                withContext(io) {
                    token = claudeTokens?.read()
                    val server = repository.server(serverId) ?: throw FileServerMissingException()
                    val service = services.service(server)
                    CommitMessageSuggestion.suggest(
                        service::locateClaude, service.agentExec(), status.root, included, status.branch.hasCommits, token,
                    )
                }
            }.onSuccess { message -> mutableState.update { it.copy(commitMessage = message) } }
                .onFailure { error -> mutableState.update { it.copy(message = error.toAgentUiText(SecretRedactor(token))) } }
            mutableState.update { it.copy(operation = null) }
        }
    }

    /** Ejecuta una operación, publica su resultado y refresca. */
    private fun perform(
        operation: GitOperation,
        onSuccess: (GitChangesUiState) -> GitChangesUiState = { it },
        body: suspend () -> UiText?,
    ) {
        if (state.value.operation != null) return
        mutableState.update { it.copy(operation = operation) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "git $operation en $path") {
                withContext(io) { body() }
            }.onSuccess { notice -> mutableState.update { onSuccess(it).copy(message = notice ?: it.message) } }
                .onFailure { error -> mutableState.update { it.copy(message = error.toGitUiText()) } }
            mutableState.update { it.copy(operation = null) }
            refreshJob?.join()
            refreshNow(reloadDiff = true)
        }
    }

    fun messageShown() = mutableState.update { it.copy(message = null) }

    companion object {
        const val POLL_INTERVAL_MILLIS = 5_000L

        fun firstLine(text: String): String? = text.lineSequence().firstOrNull { it.isNotBlank() }
    }
}

/** Texto de UI de un fallo de git (los propios con recurso; el resto, el mensaje de git). */
internal fun Throwable.toGitUiText(): UiText = when (this) {
    is GitUnavailableException -> UiText.res(R.string.git_unsupported)
    is FileServerMissingException -> UiText.res(R.string.terminal_server_missing)
    else -> toUiText()
}
