package com.iaportafolio.argos.ui.git

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitBranchInfo
import com.iaportafolio.argos.core.github.GitHubCheckState
import com.iaportafolio.argos.core.github.GitHubPullRequest
import com.iaportafolio.argos.core.github.GitHubRun
import com.iaportafolio.argos.core.github.GitHubSnapshot
import com.iaportafolio.argos.ui.common.asString
import kotlinx.coroutines.delay

/**
 * Sección «GitHub» de la pestaña Cambios (equivale a `GitHubStatusSection` de Apple): el PR de la
 * rama con su estado, revisión y checks; el CI de HEAD por workflow; abrir en GitHub, crear PR y
 * relanzar lo fallido. Desaparece si el repo no es de GitHub.
 */
@Composable
fun GitHubSection(viewModel: GitHubViewModel, branch: GitBranchInfo) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LifecycleResumeEffect(viewModel) {
        viewModel.refresh(force = true)
        viewModel.startPolling()
        onPauseOrDispose { viewModel.stopPolling() }
    }
    // Un push o un commit cambian lo que hay que mirar: se relee al momento.
    LaunchedEffect(branch) { viewModel.refresh(force = true) }
    if (state.load == GitHubLoad.NotGitHub) return

    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        when (val load = state.load) {
            GitHubLoad.Loading -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                Hint(stringResource(R.string.github_loading))
            }
            GitHubLoad.GhMissing -> Hint(stringResource(R.string.github_gh_missing))
            GitHubLoad.NotAuthenticated -> Hint(stringResource(R.string.github_not_authenticated))
            GitHubLoad.NotGitHub -> Unit
            is GitHubLoad.Failed -> Row(verticalAlignment = Alignment.CenterVertically) {
                Hint(stringResource(R.string.github_failed, load.message), Modifier.weight(1f))
                TextButton(onClick = { viewModel.refresh(force = true) }) { Text(stringResource(R.string.action_retry)) }
            }
            is GitHubLoad.Loaded -> {
                PullRequestRow(load.snapshot, state, viewModel, branch)
                CIRows(load.snapshot, state, viewModel)
            }
        }
        state.message?.let { message ->
            val text = message.asString()
            Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            LaunchedEffect(message) {
                delay(MESSAGE_MILLIS)
                viewModel.messageShown()
            }
        }
    }
    HorizontalDivider()
}

private const val MESSAGE_MILLIS = 6_000L

@Composable
private fun PullRequestRow(snapshot: GitHubSnapshot, state: GitHubUiState, viewModel: GitHubViewModel, branch: GitBranchInfo) {
    val uri = LocalUriHandler.current
    val pr = snapshot.pullRequest
    if (pr != null) {
        val label = stringResource(R.string.github_pr_open_description, pr.number, pr.title, pr.stateLabel)
        Row(
            Modifier.fillMaxWidth()
                .clickable(role = Role.Button, enabled = pr.url != null) { pr.url?.let(uri::openUri) }
                .semantics { contentDescription = label },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("●", color = prColor(pr))
            Column(Modifier.weight(1f)) {
                Text("#${pr.number} ${pr.title}", maxLines = 2, overflow = TextOverflow.Ellipsis)
                Hint(listOfNotNull(pr.stateLabel, pr.reviewLabel).joinToString(" · "))
            }
            pr.checksState?.let { CheckStateMark(it) }
        }
        return
    }
    if (snapshot.branch == null) return
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Hint(stringResource(R.string.github_no_pr), Modifier.weight(1f))
        if (state.operation == GitHubOperation.CreatePullRequest) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        }
        Box {
            TextButton(onClick = { menu = true }, enabled = state.canCreatePullRequest(branch)) {
                Text(stringResource(R.string.github_create_pr))
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.github_create_pr)) }, onClick = {
                    menu = false
                    viewModel.createPullRequest(draft = false)
                })
                DropdownMenuItem(text = { Text(stringResource(R.string.github_create_draft)) }, onClick = {
                    menu = false
                    viewModel.createPullRequest(draft = true)
                })
            }
        }
    }
    if (!state.canCreatePullRequest(branch) && state.operation == null) {
        val reason = when {
            branch.upstream == null -> R.string.github_create_needs_push
            branch.ahead > 0 -> R.string.github_create_needs_sync
            else -> null
        }
        reason?.let { Hint(stringResource(it)) }
    }
}

@Composable
private fun CIRows(snapshot: GitHubSnapshot, state: GitHubUiState, viewModel: GitHubViewModel) {
    if (snapshot.runs.isEmpty()) {
        if (snapshot.pullRequest == null) Hint(stringResource(R.string.github_no_runs, snapshot.shortSha))
    } else {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            snapshot.ciState?.let { CheckStateMark(it) }
            Text(stringResource(R.string.github_ci_title, snapshot.shortSha), style = MaterialTheme.typography.labelLarge)
        }
        snapshot.runs.forEach { run -> RunRow(run, state, viewModel) }
    }
    snapshot.warning?.let { Hint(it) }
}

@Composable
private fun RunRow(run: GitHubRun, state: GitHubUiState, viewModel: GitHubViewModel) {
    val uri = LocalUriHandler.current
    val label = stringResource(R.string.github_run_description, run.workflow, run.state.label)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CheckStateMark(run.state)
        Text(
            run.workflow,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
                .clickable(role = Role.Button, enabled = run.url != null) { run.url?.let(uri::openUri) }
                .semantics { contentDescription = label },
        )
        if (run.state == GitHubCheckState.FAILURE) {
            if (state.operation == GitHubOperation.Rerun(run.id)) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            } else {
                TextButton(onClick = { viewModel.rerunFailed(run) }, enabled = state.operation == null) {
                    Text(stringResource(R.string.github_rerun))
                }
            }
        }
    }
}

/** Marca del estado de un check o del CI (con su texto para accesibilidad). */
@Composable
private fun CheckStateMark(state: GitHubCheckState) {
    val (symbol, color) = when (state) {
        GitHubCheckState.PENDING -> "◷" to GitColors.modified
        GitHubCheckState.SUCCESS -> "✓" to GitColors.added
        GitHubCheckState.FAILURE -> "✕" to GitColors.removed
        GitHubCheckState.CANCELLED -> "⊘" to MaterialTheme.colorScheme.onSurfaceVariant
        GitHubCheckState.SKIPPED -> "–" to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Text(symbol, color = color, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { contentDescription = state.label })
}

private fun prColor(pr: GitHubPullRequest): Color = when (pr.state) {
    GitHubPullRequest.State.MERGED -> Color(0xFFA371F7)
    GitHubPullRequest.State.CLOSED -> GitColors.removed
    GitHubPullRequest.State.OPEN -> if (pr.isDraft) Color(0xFF8B949E) else GitColors.added
}

@Composable
private fun Hint(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier)
}
