package com.iaportafolio.argos.ui.projects

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.projects.ProjectDefaults

/** Diálogos de proyectos: confirmaciones, formulario e importación. */
@Composable
internal fun ProjectDialogs(
    dialog: ProjectsDialog?,
    actions: ProjectsActions,
    folderPicker: @Composable (startPath: String, onPick: (String) -> Unit, onDismiss: () -> Unit) -> Unit,
) {
    when (dialog) {
        is ProjectsDialog.Confirm -> ConfirmDialog(dialog, actions)
        is ProjectsDialog.Form -> ProjectFormDialog(dialog.form, actions, folderPicker)
        is ProjectsDialog.Import -> ImportDialog(dialog.state, actions)
        null -> Unit
    }
}

/** Textos de `ProjectConfirmation` (core, idénticos a los de Apple). */
@Composable
private fun ConfirmDialog(dialog: ProjectsDialog.Confirm, actions: ProjectsActions) {
    val confirmation = dialog.confirmation
    AlertDialog(
        onDismissRequest = actions::dismissProjectDialog,
        title = { Text(confirmation.title) },
        text = { Text(confirmation.message) },
        confirmButton = {
            TextButton(onClick = actions::confirmProjectAction, enabled = !dialog.isSubmitting) {
                Text(confirmation.actionLabel, color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(onClick = actions::dismissProjectDialog, enabled = !dialog.isSubmitting) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProjectFormDialog(
    form: ProjectFormState,
    actions: ProjectsActions,
    folderPicker: @Composable (startPath: String, onPick: (String) -> Unit, onDismiss: () -> Unit) -> Unit,
) {
    var pickingFolder by rememberSaveable { mutableStateOf(false) }
    val title = stringResource(
        when (form.mode) {
            ProjectFormMode.New -> R.string.projects_form_new
            is ProjectFormMode.Edit -> R.string.projects_form_edit
            is ProjectFormMode.Convert -> R.string.projects_form_convert
        },
    )
    Dialog(onDismissRequest = actions::dismissProjectDialog, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(title) },
                    navigationIcon = {
                        IconButton(onClick = actions::dismissProjectDialog, enabled = !form.isSubmitting) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_cancel))
                        }
                    },
                    actions = {
                        if (form.isSubmitting) CircularProgressIndicator(Modifier.size(24.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                        TextButton(onClick = actions::submitForm, enabled = form.canSubmit) {
                            Text(stringResource(if (form.mode is ProjectFormMode.Edit) R.string.action_save else R.string.projects_form_create))
                        }
                    },
                )
            },
        ) { padding ->
            Column(
                Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                form.error?.let { FormError(it) }
                IdentitySection(form, actions)
                FolderSection(form, actions, onBrowse = { pickingFolder = true })
                CommandSection(form, actions)
            }
        }
    }
    if (pickingFolder) {
        folderPicker(form.path, { picked -> actions.onFolderPicked(picked); pickingFolder = false }, { pickingFolder = false })
    }
}

@Composable
private fun FormError(message: String) {
    Text(
        message,
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
    )
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.semantics { heading() })
}

@Composable
private fun IdentitySection(form: ProjectFormState, actions: ProjectsActions) {
    SectionTitle(stringResource(R.string.projects_form_identity))
    OutlinedTextField(
        value = form.name,
        onValueChange = actions::onFormName,
        label = { Text(stringResource(R.string.projects_form_name)) },
        isError = form.nameError != null,
        supportingText = form.nameError?.let { { Text(it) } },
        singleLine = true,
        enabled = !form.isSubmitting,
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
        modifier = Modifier.fillMaxWidth(),
    )
    var groupMenu by remember { mutableStateOf(false) }
    Box {
        OutlinedTextField(
            value = form.group,
            onValueChange = actions::onFormGroup,
            label = { Text(stringResource(R.string.projects_form_group)) },
            placeholder = { Text(stringResource(R.string.projects_form_group_placeholder)) },
            isError = form.groupError != null,
            supportingText = {
                Text(
                    form.groupError
                        ?: if (form.isNewGroup) stringResource(R.string.projects_form_group_new, form.group.trim())
                        else stringResource(R.string.projects_form_group_hint),
                )
            },
            singleLine = true,
            enabled = !form.isSubmitting,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
            trailingIcon = {
                IconButton(onClick = { groupMenu = true }, enabled = !form.isSubmitting) {
                    Icon(Icons.Filled.ArrowDropDown, contentDescription = stringResource(R.string.projects_form_group_pick))
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
        DropdownMenu(expanded = groupMenu, onDismissRequest = { groupMenu = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.projects_form_no_group)) },
                onClick = { groupMenu = false; actions.onFormGroup("") },
            )
            form.existingGroups.forEach { group ->
                DropdownMenuItem(text = { Text(group) }, onClick = { groupMenu = false; actions.onFormGroup(group) })
            }
        }
    }
}

@Composable
private fun FolderSection(form: ProjectFormState, actions: ProjectsActions, onBrowse: () -> Unit) {
    SectionTitle(stringResource(R.string.projects_form_folder))
    OutlinedTextField(
        value = form.path,
        onValueChange = actions::onFormPath,
        label = { Text(stringResource(R.string.projects_form_path)) },
        placeholder = { Text(stringResource(R.string.projects_form_path_placeholder)) },
        isError = form.pathError != null,
        supportingText = {
            Text(
                form.pathError ?: if (form.isPrefilling) {
                    stringResource(R.string.projects_form_path_prefilling)
                } else {
                    stringResource(R.string.projects_form_path_hint)
                },
            )
        },
        singleLine = true,
        enabled = !form.isSubmitting,
        textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
        modifier = Modifier.fillMaxWidth(),
    )
    OutlinedButton(onClick = onBrowse, enabled = !form.isSubmitting) { Text(stringResource(R.string.projects_form_browse)) }
}

@Composable
private fun CommandSection(form: ProjectFormState, actions: ProjectsActions) {
    SectionTitle(stringResource(R.string.projects_form_command))
    val defaultLabel = form.defaultCommand.ifEmpty { stringResource(R.string.projects_form_command_nothing) }
    Column(Modifier.selectableGroup()) {
        CommandOption(stringResource(R.string.projects_form_command_default, defaultLabel), form.command == StartupChoice.Default, !form.isSubmitting) {
            actions.onFormCommand(StartupChoice.Default)
        }
        ProjectDefaults.PRESETS.forEach { preset ->
            val choice = StartupChoice.Preset(preset.command)
            val label = if (preset.command.isEmpty()) preset.label else "${preset.label} · ${preset.command}"
            CommandOption(label, form.command == choice, !form.isSubmitting) { actions.onFormCommand(choice) }
        }
        CommandOption(stringResource(R.string.projects_form_command_custom), form.command == StartupChoice.Custom, !form.isSubmitting) {
            actions.onFormCommand(StartupChoice.Custom)
        }
    }
    if (form.command == StartupChoice.Custom) {
        OutlinedTextField(
            value = form.customCommand,
            onValueChange = actions::onFormCustomCommand,
            label = { Text(stringResource(R.string.projects_form_command_label)) },
            placeholder = { Text(stringResource(R.string.projects_form_command_placeholder)) },
            singleLine = true,
            enabled = !form.isSubmitting,
            textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun CommandOption(label: String, selected: Boolean, enabled: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onSelect),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null, enabled = enabled)
        Text(label, modifier = Modifier.padding(start = 12.dp), style = MaterialTheme.typography.bodyMedium)
    }
}

/** Importar sesiones sueltas como proyectos (port de `ImportProjectsSheet`). */
@Composable
private fun ImportDialog(state: ImportState, actions: ProjectsActions) {
    AlertDialog(
        onDismissRequest = actions::dismissProjectDialog,
        title = { Text(stringResource(R.string.projects_import_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.projects_import_body), style = MaterialTheme.typography.bodyMedium)
                state.error?.let { FormError(it) }
                when {
                    state.isLoading -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text(stringResource(R.string.projects_import_loading))
                    }
                    state.candidates.isEmpty() && state.error == null -> Text(stringResource(R.string.projects_import_empty))
                    else -> LazyColumn(Modifier.heightIn(max = IMPORT_LIST_MAX_HEIGHT)) {
                        items(state.candidates, key = { it.id }) { candidate ->
                            ImportRow(candidate.sessionName, candidate.path, candidate.id in state.selected, !state.isImporting) {
                                actions.toggleImportCandidate(candidate.id)
                            }
                            HorizontalDivider()
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = actions::confirmImport, enabled = state.canImport) {
                Text(stringResource(R.string.projects_import_confirm, state.selected.size))
            }
        },
        dismissButton = {
            TextButton(onClick = actions::dismissProjectDialog, enabled = !state.isImporting) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}

private val IMPORT_LIST_MAX_HEIGHT = 320.dp

@Composable
private fun ImportRow(name: String, path: String, checked: Boolean, enabled: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(value = checked, enabled = enabled, role = Role.Checkbox, onValueChange = { onToggle() })
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = checked, onCheckedChange = null, enabled = enabled)
        Column(Modifier.padding(start = 12.dp)) {
            Text(name, style = MaterialTheme.typography.bodyLarge)
            Text(
                path,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
        }
    }
}

/** Fila pulsable genérica del selector de carpetas. */
@Composable
internal fun FolderRow(label: String, onClick: () -> Unit, leading: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        leading()
        Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
