package com.iaportafolio.argos.ui.git

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitBranchInfo
import com.iaportafolio.argos.core.git.GitFileChange
import com.iaportafolio.argos.core.git.GitRepositoryStatus
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString

/**
 * Pestaña «Cambios» de un proyecto (equivale a `GitChangesView` de iOS): archivos cambiados con
 * su casilla para el commit, diff del elegido, descartar, commit, subir y traer. En móvil, lista
 * o diff a pantalla completa; con [twoPane], lista | diff.
 */
@Composable
fun GitChangesScreen(
    viewModel: GitChangesViewModel,
    twoPane: Boolean,
    onExit: () -> Unit,
    gitHub: @Composable (root: String, branch: GitBranchInfo) -> Unit = { _, _ -> },
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, viewModel::messageShown)
    LifecycleResumeEffect(viewModel) {
        viewModel.refresh()
        viewModel.startPolling()
        onPauseOrDispose { viewModel.stopPolling() }
    }
    val showingDiff = !twoPane && state.selectedChange != null
    BackHandler(enabled = showingDiff) { viewModel.select(null) }

    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                twoPane -> Row(Modifier.fillMaxSize()) {
                    ChangesPane(state, viewModel, onExit, gitHub, Modifier.width(LIST_PANE_WIDTH).fillMaxHeight())
                    VerticalDivider()
                    DiffPane(state, onClose = null, Modifier.weight(1f))
                }
                showingDiff -> DiffPane(state, onClose = { viewModel.select(null) }, Modifier.fillMaxSize())
                else -> ChangesPane(state, viewModel, onExit, gitHub, Modifier.fillMaxSize())
            }
        }
    }
    state.confirmDiscard?.let { change -> DiscardDialog(change, viewModel) }
}

private val LIST_PANE_WIDTH = 400.dp

@Composable
private fun ChangesPane(
    state: GitChangesUiState,
    viewModel: GitChangesViewModel,
    onExit: () -> Unit,
    gitHub: @Composable (root: String, branch: GitBranchInfo) -> Unit,
    modifier: Modifier,
) {
    Column(modifier.imePadding()) {
        ChangesTopBar(state, viewModel, onExit)
        HorizontalDivider()
        Box(Modifier.weight(1f)) {
            when (val load = state.load) {
                GitPanelLoad.Loading -> ProgressMessage(stringResource(R.string.git_loading))
                GitPanelLoad.GitMissing -> StatusMessage(
                    icon = painterResource(R.drawable.ic_commit),
                    title = stringResource(R.string.git_missing_title),
                    body = stringResource(R.string.git_missing),
                )
                GitPanelLoad.NotRepository -> StatusMessage(
                    icon = painterResource(R.drawable.ic_commit),
                    title = stringResource(R.string.git_not_repo_title),
                    body = stringResource(R.string.git_not_repo),
                )
                is GitPanelLoad.Failed -> StatusMessage(
                    icon = rememberVectorPainter(Icons.Filled.Warning),
                    title = stringResource(R.string.git_failed_title),
                    body = load.message.asString(),
                ) { Button(onClick = { viewModel.refresh() }) { Text(stringResource(R.string.action_retry)) } }
                is GitPanelLoad.Loaded -> RepositoryContent(load.status, state, viewModel, gitHub)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChangesTopBar(state: GitChangesUiState, viewModel: GitChangesViewModel, onExit: () -> Unit) {
    TopAppBar(
        windowInsets = WindowInsets(0),
        title = {
            Column {
                Text(stringResource(R.string.project_tab_changes), maxLines = 1)
                state.status?.let { status ->
                    Text(
                        branchLine(status.branch),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        },
        navigationIcon = {
            IconButton(onClick = onExit) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
            }
        },
        actions = {
            if (state.operation != null) {
                CircularProgressIndicator(Modifier.padding(horizontal = 12.dp).size(20.dp), strokeWidth = 2.dp)
            }
            IconButton(onClick = { viewModel.refresh() }, enabled = state.operation == null) {
                Icon(Icons.Filled.Refresh, contentDescription = stringResource(R.string.git_refresh))
            }
        },
    )
}

/** «main → origin/main» con los avisos de la rama (sin commits, remoto borrado). */
@Composable
private fun branchLine(branch: GitBranchInfo): String {
    val name = branch.name ?: stringResource(R.string.git_detached)
    val parts = listOfNotNull(
        branch.upstream?.let { "$name → $it" } ?: name,
        stringResource(R.string.git_no_commits).takeIf { !branch.hasCommits },
        stringResource(R.string.git_upstream_gone).takeIf { branch.upstreamGone },
    )
    return parts.joinToString(" · ")
}

@Composable
private fun RepositoryContent(
    status: GitRepositoryStatus,
    state: GitChangesUiState,
    viewModel: GitChangesViewModel,
    gitHub: @Composable (root: String, branch: GitBranchInfo) -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        SyncRow(status.branch, state, viewModel)
        gitHub(status.root, status.branch)
        if (state.hasConflicts) Warning(stringResource(R.string.git_conflicts))
        if (status.truncated) Warning(stringResource(R.string.git_truncated))
        if (status.isClean) {
            StatusMessage(
                icon = painterResource(R.drawable.ic_commit),
                title = stringResource(R.string.git_clean_title),
                body = stringResource(R.string.git_clean),
                modifier = Modifier.weight(1f),
            )
            return@Column
        }
        IncludeAllRow(state, viewModel)
        LazyColumn(Modifier.weight(1f)) {
            items(state.changes, key = { it.path }) { change ->
                ChangeRow(change, state, viewModel)
            }
        }
        HorizontalDivider()
        CommitBox(state, viewModel)
    }
}

/** Traer / subir, con cuántos commits hay en cada sentido. */
@Composable
private fun SyncRow(branch: GitBranchInfo, state: GitChangesUiState, viewModel: GitChangesViewModel) {
    if (branch.upstream == null && !state.canPush) return
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedButton(onClick = viewModel::pull, enabled = state.canPull, modifier = Modifier.weight(1f)) {
            Icon(painterResource(R.drawable.ic_download), contentDescription = null, modifier = Modifier.size(18.dp))
            Text(
                if (branch.behind > 0) stringResource(R.string.git_pull_behind, branch.behind) else stringResource(R.string.git_pull),
                modifier = Modifier.padding(start = 6.dp),
            )
        }
        OutlinedButton(onClick = viewModel::push, enabled = state.canPush, modifier = Modifier.weight(1f)) {
            Icon(painterResource(R.drawable.ic_upload), contentDescription = null, modifier = Modifier.size(18.dp))
            Text(
                if (branch.ahead > 0) stringResource(R.string.git_push_ahead, branch.ahead) else stringResource(R.string.git_push),
                modifier = Modifier.padding(start = 6.dp),
            )
        }
    }
}

@Composable
private fun Warning(text: String) {
    Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth()) {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onErrorContainer,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun IncludeAllRow(state: GitChangesUiState, viewModel: GitChangesViewModel) {
    val all = state.includedCount == state.changes.size
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = { viewModel.setAllIncluded(!all) }, enabled = state.operation == null) {
            Text(stringResource(if (all) R.string.git_include_none else R.string.git_include_all))
        }
    }
}

@Composable
private fun ChangeRow(change: GitFileChange, state: GitChangesUiState, viewModel: GitChangesViewModel) {
    val selected = change.path == state.selectedPath
    val background = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface
    Surface(color = background) {
        Row(
            Modifier.fillMaxWidth()
                .clickable(role = Role.Button) { viewModel.select(change.path) }
                .padding(end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val includeLabel = stringResource(R.string.git_include_file, change.fileName)
            Checkbox(
                checked = state.isIncluded(change),
                onCheckedChange = { viewModel.setIncluded(change, it) },
                enabled = state.operation == null,
                modifier = Modifier.semantics { contentDescription = includeLabel },
            )
            ChangeBadge(change)
            Column(Modifier.weight(1f).padding(start = 10.dp, top = 8.dp, bottom = 8.dp)) {
                Text(change.fileName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val detail = listOfNotNull(change.originalPath?.let { "← $it" }, change.directory.ifEmpty { null })
                if (detail.isNotEmpty()) {
                    Text(
                        detail.joinToString(" · "),
                        maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            IconButton(
                onClick = { viewModel.requestDiscard(change) },
                enabled = state.operation == null && !change.isConflicted,
            ) {
                Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.git_discard))
            }
        }
    }
}

/** Letra del tipo de cambio (M, A, D, R, U, !) en su color. */
@Composable
private fun ChangeBadge(change: GitFileChange) {
    val kind = change.kind
    Text(
        kind.letter,
        color = GitColors.kind(kind),
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.semantics { contentDescription = kind.label },
    )
}

@Composable
private fun CommitBox(state: GitChangesUiState, viewModel: GitChangesViewModel) {
    Row(
        Modifier.fillMaxWidth().padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = state.commitMessage,
            onValueChange = viewModel::onCommitMessage,
            placeholder = { Text(stringResource(R.string.git_commit_hint)) },
            enabled = state.operation == null,
            maxLines = 4,
            modifier = Modifier.weight(1f),
        )
        Button(onClick = viewModel::commit, enabled = state.canCommit) {
            Icon(painterResource(R.drawable.ic_commit), contentDescription = null, modifier = Modifier.size(18.dp))
            Text(stringResource(R.string.git_commit_action, state.includedCount), modifier = Modifier.padding(start = 6.dp))
        }
    }
}

@Composable
private fun DiscardDialog(change: GitFileChange, viewModel: GitChangesViewModel) {
    AlertDialog(
        onDismissRequest = viewModel::dismissDiscard,
        title = { Text(stringResource(R.string.git_discard_title, change.fileName)) },
        text = {
            Text(stringResource(if (change.isUntracked) R.string.git_discard_untracked_body else R.string.git_discard_body))
        },
        confirmButton = {
            TextButton(onClick = viewModel::confirmDiscard) {
                Text(stringResource(R.string.git_discard), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = viewModel::dismissDiscard) { Text(stringResource(R.string.action_cancel)) } },
    )
}
