package com.iaportafolio.argos.ui.projects

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitWorktree
import com.iaportafolio.argos.core.git.GitWorktreeListing
import com.iaportafolio.argos.ui.common.asString
import com.iaportafolio.argos.ui.git.GitColors

/**
 * «Ramas en paralelo» de un proyecto (equivale a `WorktreesSheet` del Mac): los worktrees del
 * repositorio y el alta de una rama nueva (o existente) en su carpeta, con su agente.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorktreesDialog(viewModel: WorktreesViewModel, onDismiss: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(stringResource(R.string.worktrees_title)) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_close))
                        }
                    },
                    actions = {
                        if (state.isWorking) CircularProgressIndicator(Modifier.size(24.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                    },
                )
            },
        ) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Note(stringResource(R.string.worktrees_subtitle))
                state.message?.let { Text(it.asString(), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyMedium) }
                when (val load = state.load) {
                    WorktreesLoad.Loading -> CircularProgressIndicator()
                    WorktreesLoad.GitMissing -> Note(stringResource(R.string.git_missing))
                    WorktreesLoad.NotRepository -> Note(stringResource(R.string.git_not_repo))
                    is WorktreesLoad.Failed -> Row(verticalAlignment = Alignment.CenterVertically) {
                        Note(load.message.asString(), Modifier.weight(1f))
                        TextButton(onClick = viewModel::reload) { Text(stringResource(R.string.action_retry)) }
                    }
                    is WorktreesLoad.Loaded -> {
                        Heading(stringResource(R.string.worktrees_list))
                        load.listing.worktrees.forEach { WorktreeRow(it, state, viewModel) }
                        HorizontalDivider()
                        NewBranchForm(load.listing, state, viewModel)
                    }
                }
            }
        }
    }
    state.confirmRemoval?.let { worktree -> RemovalDialog(worktree, viewModel) }
}

@Composable
private fun WorktreeRow(worktree: GitWorktree, state: WorktreesUiState, viewModel: WorktreesViewModel) {
    val project = state.projectFor(worktree)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f)) {
            val tags = listOfNotNull(
                stringResource(R.string.worktrees_main).takeIf { worktree.isMain },
                stringResource(R.string.worktrees_running).takeIf { state.isRunning(worktree) },
                worktree.changedCount?.takeIf { it > 0 }?.let { stringResource(R.string.git_badge_changed, it) },
                stringResource(R.string.worktrees_prunable).takeIf { worktree.isPrunable },
            )
            Text(
                (listOf(worktree.displayBranch) + tags).joinToString(" · "),
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                project?.let { "${it.name} · ${worktree.path}" } ?: worktree.path,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
        }
        if (project == null && !worktree.isMain && worktree.branch != null) {
            TextButton(onClick = { viewModel.adopt(worktree) }, enabled = !state.isWorking) {
                Text(stringResource(R.string.worktrees_adopt))
            }
        }
        if (!worktree.isMain) {
            IconButton(onClick = { viewModel.requestRemoval(worktree) }, enabled = !state.isWorking && !worktree.isLocked) {
                Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.worktrees_remove_for, worktree.displayBranch), tint = GitColors.removed)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewBranchForm(listing: GitWorktreeListing, state: WorktreesUiState, viewModel: WorktreesViewModel) {
    val enabled = !state.isWorking
    Heading(stringResource(R.string.worktrees_new))
    val options = listOf(R.string.worktrees_branch_new to true, R.string.worktrees_branch_existing to false)
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, (label, creates) ->
            SegmentedButton(
                selected = state.createsBranch == creates,
                onClick = { viewModel.onCreatesBranch(creates) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
                enabled = enabled,
            ) { Text(stringResource(label)) }
        }
    }
    if (state.createsBranch) {
        OutlinedTextField(
            value = state.branch,
            onValueChange = viewModel::onBranch,
            label = { Text(stringResource(R.string.worktrees_branch_name)) },
            placeholder = { Text("feat/login") },
            singleLine = true,
            enabled = enabled,
            textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
            modifier = Modifier.fillMaxWidth(),
        )
        Choice(
            label = stringResource(R.string.worktrees_base),
            value = if (state.base == "HEAD") stringResource(R.string.worktrees_base_head) else state.base,
            options = state.baseOptions,
            optionLabel = { if (it == "HEAD") stringResource(R.string.worktrees_base_head) else it },
            enabled = enabled,
            onPick = viewModel::onBase,
        )
    } else if (listing.freeBranches.isEmpty()) {
        Note(stringResource(R.string.worktrees_no_free))
    } else {
        Choice(
            label = stringResource(R.string.worktrees_branch_name),
            value = state.branch,
            options = listing.freeBranches,
            optionLabel = { it },
            enabled = enabled,
            onPick = viewModel::onBranch,
        )
    }
    OutlinedTextField(
        value = state.path,
        onValueChange = viewModel::onPath,
        label = { Text(stringResource(R.string.worktrees_folder)) },
        singleLine = true,
        enabled = enabled,
        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
        supportingText = {
            val error = state.validationError
            when {
                state.branch.isEmpty() -> Unit
                error != null -> Text(error, color = MaterialTheme.colorScheme.error)
                else -> Text(stringResource(R.string.worktrees_will_create, state.projectName))
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.worktrees_start_agent), Modifier.weight(1f))
        Switch(checked = state.startsAgent, onCheckedChange = viewModel::onStartsAgent, enabled = enabled)
    }
    Button(onClick = viewModel::create, enabled = state.canCreate, modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.worktrees_create))
    }
}

@Composable
private fun Choice(
    label: String,
    value: String,
    options: List<String>,
    optionLabel: @Composable (String) -> String,
    enabled: Boolean,
    onPick: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        OutlinedTextField(
            value = value,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            singleLine = true,
            enabled = enabled,
            trailingIcon = {
                IconButton(onClick = { open = true }, enabled = enabled) {
                    Icon(Icons.Filled.ArrowDropDown, contentDescription = label)
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { option ->
                DropdownMenuItem(text = { Text(optionLabel(option)) }, onClick = {
                    open = false
                    onPick(option)
                })
            }
        }
    }
}

@Composable
private fun RemovalDialog(worktree: GitWorktree, viewModel: WorktreesViewModel) {
    val changed = worktree.changedCount ?: 0
    AlertDialog(
        onDismissRequest = viewModel::dismissRemoval,
        title = { Text(stringResource(R.string.worktrees_remove_title, worktree.displayBranch)) },
        text = {
            Text(
                stringResource(R.string.worktrees_remove_body) +
                    if (changed > 0) "\n\n" + stringResource(R.string.worktrees_remove_changes, changed) else "",
            )
        },
        confirmButton = {
            TextButton(onClick = viewModel::confirmRemoval) {
                Text(
                    stringResource(if (changed > 0) R.string.worktrees_remove_force else R.string.worktrees_remove),
                    color = MaterialTheme.colorScheme.error,
                )
            }
        },
        dismissButton = { TextButton(onClick = viewModel::dismissRemoval) { Text(stringResource(R.string.action_cancel)) } },
    )
}

@Composable
private fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.semantics { heading() })
}

@Composable
private fun Note(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier)
}
