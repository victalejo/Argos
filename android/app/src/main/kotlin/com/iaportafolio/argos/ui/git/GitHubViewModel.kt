package com.iaportafolio.argos.ui.git

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitBranchInfo
import com.iaportafolio.argos.core.github.GitHubOperations
import com.iaportafolio.argos.core.github.GitHubPullRequest
import com.iaportafolio.argos.core.github.GitHubRun
import com.iaportafolio.argos.core.github.GitHubSnapshot
import com.iaportafolio.argos.core.github.GitHubStatusResult
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
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
import java.time.Duration
import java.time.Instant

/** Estado de GitHub del repositorio (port de `GitHubPanelState`). */
sealed interface GitHubLoad {
    data object Loading : GitHubLoad
    data object GhMissing : GitHubLoad
    data object NotAuthenticated : GitHubLoad
    data object NotGitHub : GitHubLoad
    data class Loaded(val snapshot: GitHubSnapshot) : GitHubLoad
    data class Failed(val message: String) : GitHubLoad
}

/** Operación de GitHub en curso. */
sealed interface GitHubOperation {
    data object CreatePullRequest : GitHubOperation
    data class Rerun(val runId: Long) : GitHubOperation
}

data class GitHubUiState(
    val load: GitHubLoad = GitHubLoad.Loading,
    val operation: GitHubOperation? = null,
    val message: UiText? = null,
) {
    val snapshot: GitHubSnapshot? get() = (load as? GitHubLoad.Loaded)?.snapshot

    /** Se puede abrir un PR: hay rama, no tiene PR abierto y está subida y al día. */
    fun canCreatePullRequest(branch: GitBranchInfo): Boolean {
        val snapshot = snapshot ?: return false
        if (operation != null || snapshot.branch == null) return false
        if (snapshot.pullRequest?.state == GitHubPullRequest.State.OPEN) return false
        return branch.upstream != null && !branch.upstreamGone && branch.ahead == 0
    }

    /** Hay CI o checks en curso: se relee más a menudo. */
    val isPending: Boolean
        get() = snapshot?.isCIRunning == true ||
            snapshot?.pullRequest?.checks?.any { it.state == com.iaportafolio.argos.core.github.GitHubCheckState.PENDING } == true
}

/**
 * Sección «GitHub» de la pestaña Cambios (port de `GitHubStatusModel` de Apple): PR de la rama y
 * CI de HEAD con el `gh` del servidor; crear PR y relanzar lo fallido. Cada lectura toca la API de
 * GitHub, así que se espacia ([REFRESH_INTERVAL], o [PENDING_INTERVAL] con CI en curso). Con CI en
 * curso se apunta en [onCIPending] para avisar al terminar aunque se cierre la pantalla.
 */
class GitHubViewModel(
    private val serverId: String,
    private val root: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
    private val onCIPending: (sha: String) -> Unit = {},
    private val clock: () -> Instant = Instant::now,
) : ViewModel() {

    private val mutableState = MutableStateFlow(GitHubUiState())
    val state: StateFlow<GitHubUiState> = mutableState.asStateFlow()

    private var lastRefresh: Instant? = null
    private var refreshJob: Job? = null
    private var pollJob: Job? = null

    private suspend fun gitHub(): GitHubOperations {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.service(server) as? GitHubOperations ?: throw GitUnavailableException()
    }

    /** Relee si toca ([force]: ya, p. ej. al pulsar recargar o tras un push). */
    fun refresh(force: Boolean = false) {
        val now = clock()
        val interval = if (state.value.isPending) PENDING_INTERVAL else REFRESH_INTERVAL
        val last = lastRefresh
        if (!force && last != null && Duration.between(last, now) < interval) return
        if (refreshJob?.isActive == true) return
        lastRefresh = now
        refreshJob = viewModelScope.launch { refreshNow() }
    }

    private suspend fun refreshNow() {
        logFailures(ArgosLog.TAG_SSH, "gh status de $root") {
            withContext(io) { gitHub().gitHubStatus(root) }
        }.onSuccess { result ->
            mutableState.update { state ->
                when (result) {
                    GitHubStatusResult.GhMissing -> state.copy(load = GitHubLoad.GhMissing)
                    GitHubStatusResult.NotAuthenticated -> state.copy(load = GitHubLoad.NotAuthenticated)
                    GitHubStatusResult.NotGitHub -> state.copy(load = GitHubLoad.NotGitHub)
                    // Con datos ya visibles, un fallo pasajero (red) no los borra.
                    is GitHubStatusResult.Failed -> if (state.snapshot == null) state.copy(load = GitHubLoad.Failed(result.message)) else state
                    is GitHubStatusResult.Loaded -> state.copy(load = GitHubLoad.Loaded(result.snapshot))
                }
            }
            (result as? GitHubStatusResult.Loaded)?.snapshot?.takeIf { it.isCIRunning }?.let { onCIPending(it.headSha) }
        }.onFailure { error ->
            mutableState.update { if (it.snapshot == null) it.copy(load = GitHubLoad.Failed(error.toGitUiTextMessage())) else it }
        }
    }

    /** Relectura periódica mientras la pantalla esté en primer plano. */
    fun startPolling() {
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            while (true) {
                delay(TICK_MILLIS)
                if (state.value.operation == null) refresh()
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    fun createPullRequest(draft: Boolean) = perform(GitHubOperation.CreatePullRequest) {
        val url = gitHub().gitHubCreatePullRequest(root, draft)
        url?.let { UiText.res(R.string.github_pr_created_url, it) } ?: UiText.res(R.string.github_pr_created)
    }

    fun rerunFailed(run: GitHubRun) = perform(GitHubOperation.Rerun(run.id)) {
        gitHub().gitHubRerunFailed(root, run.id)
        UiText.res(R.string.github_rerun_done, run.workflow)
    }

    private fun perform(operation: GitHubOperation, body: suspend () -> UiText) {
        if (state.value.operation != null) return
        mutableState.update { it.copy(operation = operation) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "gh $operation en $root") { withContext(io) { body() } }
                .onSuccess { notice -> mutableState.update { it.copy(message = notice) } }
                .onFailure { error -> mutableState.update { it.copy(message = error.toGitUiText()) } }
            mutableState.update { it.copy(operation = null) }
            refreshJob?.join()
            lastRefresh = clock()
            refreshNow()
        }
    }

    fun messageShown() = mutableState.update { it.copy(message = null) }

    companion object {
        val REFRESH_INTERVAL: Duration = Duration.ofSeconds(60)
        val PENDING_INTERVAL: Duration = Duration.ofSeconds(20)
        const val TICK_MILLIS = 5_000L
    }
}

/** Mensaje en texto plano de un fallo (el estado de carga guarda texto, no recursos). */
private fun Throwable.toGitUiTextMessage(): String = (toGitUiText() as? UiText.Plain)?.value ?: (message ?: "Error")
