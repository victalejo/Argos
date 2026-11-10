package com.iaportafolio.argos.ui.projects

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R

/** Origen del proyecto nuevo: carpeta existente o «Clonar de GitHub» (Apple: `Picker` segmentado). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SourceSection(form: ProjectFormState, actions: ProjectsActions) {
    Title(stringResource(R.string.clone_source))
    val options = listOf(R.string.clone_source_folder to false, R.string.clone_source_github to true)
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, (label, clone) ->
            SegmentedButton(
                selected = (form.clone != null) == clone,
                onClick = { actions.onFormClone(clone) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
                enabled = !form.isSubmitting,
            ) { Text(stringResource(label)) }
        }
    }
}

/** Repositorio, dónde clonarlo y la carpeta (equivale a `GitHubCloneFields` del Mac). */
@Composable
internal fun CloneSection(clone: CloneFormState, isSubmitting: Boolean, actions: ProjectsActions, onBrowse: () -> Unit) {
    val enabled = !isSubmitting && clone.clonedPath == null
    Title(stringResource(R.string.clone_source_github))
    var menu by remember { mutableStateOf(false) }
    Box {
        OutlinedTextField(
            value = clone.repository,
            onValueChange = actions::onCloneRepository,
            label = { Text(stringResource(R.string.clone_repository)) },
            placeholder = { Text(stringResource(R.string.clone_repository_placeholder)) },
            supportingText = { Text(stringResource(R.string.clone_repository_hint)) },
            singleLine = true,
            enabled = enabled,
            textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
            trailingIcon = {
                val repos = (clone.repositories as? CloneRepositories.Loaded)?.repositories.orEmpty()
                if (repos.isNotEmpty()) {
                    IconButton(onClick = { menu = true }, enabled = enabled) {
                        Icon(Icons.Filled.ArrowDropDown, contentDescription = stringResource(R.string.clone_repository_pick))
                    }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            (clone.repositories as? CloneRepositories.Loaded)?.repositories.orEmpty().forEach { repo ->
                val suffix = if (repo.isPrivate) " · ${stringResource(R.string.clone_private)}" else ""
                DropdownMenuItem(text = { Text(repo.nameWithOwner + suffix) }, onClick = {
                    menu = false
                    actions.onCloneChoose(repo)
                })
            }
        }
    }
    RepositoriesStatus(clone.repositories, actions)

    Title(stringResource(R.string.clone_where))
    OutlinedTextField(
        value = clone.parent,
        onValueChange = actions::onCloneParent,
        label = { Text(stringResource(R.string.clone_parent)) },
        singleLine = true,
        enabled = enabled,
        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedButton(onClick = onBrowse, enabled = enabled) { Text(stringResource(R.string.projects_form_browse)) }
    OutlinedTextField(
        value = clone.folder,
        onValueChange = actions::onCloneFolder,
        label = { Text(stringResource(R.string.clone_folder)) },
        isError = clone.repository.isNotEmpty() && clone.validationError != null,
        supportingText = {
            val error = clone.validationError
            Text(
                when {
                    clone.clonedPath != null -> stringResource(R.string.clone_already_cloned, clone.clonedPath)
                    clone.repository.isNotEmpty() && error != null -> error
                    else -> stringResource(R.string.clone_destination, clone.destination)
                },
            )
        },
        singleLine = true,
        enabled = enabled,
        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun RepositoriesStatus(repositories: CloneRepositories, actions: ProjectsActions) {
    when (repositories) {
        CloneRepositories.Idle, is CloneRepositories.Loaded -> Unit
        CloneRepositories.Loading -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Note(stringResource(R.string.clone_loading))
        }
        CloneRepositories.GhMissing -> Note(stringResource(R.string.clone_gh_missing))
        CloneRepositories.NotAuthenticated -> Note(stringResource(R.string.clone_not_authenticated))
        is CloneRepositories.Failed -> Row(verticalAlignment = Alignment.CenterVertically) {
            Note(repositories.message, Modifier.weight(1f))
            TextButton(onClick = actions::retryCloneRepositories) { Text(stringResource(R.string.action_retry)) }
        }
    }
}

@Composable
private fun Title(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.semantics { heading() })
}

@Composable
private fun Note(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier)
}
