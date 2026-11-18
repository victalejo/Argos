package com.iaportafolio.argos.ui.servers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.projects.ProjectDefaults

/**
 * Comando de arranque predeterminado de los proyectos (Ajustes de Apple): lo que se teclea al abrir
 * un proyecto sin comando propio. Preajustes de [ProjectDefaults.PRESETS] o uno personalizado; el valor
 * de fábrica sigue siendo [ProjectDefaults.FACTORY_STARTUP_COMMAND].
 */
@Composable
fun StartupCommandDialog(current: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    val presetCommands = ProjectDefaults.PRESETS.map { it.command }
    var custom by rememberSaveable { mutableStateOf(current.takeUnless { it in presetCommands }.orEmpty()) }
    var selected by rememberSaveable { mutableStateOf(if (current in presetCommands) current else null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.startup_command_title)) },
        text = {
            Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.startup_command_help), style = MaterialTheme.typography.bodySmall)
                ProjectDefaults.PRESETS.forEach { preset ->
                    Choice(
                        label = preset.label,
                        detail = preset.command.ifEmpty { null },
                        selected = selected == preset.command,
                        onSelect = { selected = preset.command },
                    )
                }
                Choice(stringResource(R.string.startup_command_custom), detail = null, selected = selected == null, onSelect = { selected = null })
                if (selected == null) {
                    OutlinedTextField(
                        value = custom,
                        onValueChange = { custom = it },
                        singleLine = true,
                        placeholder = { Text(stringResource(R.string.projects_form_command_placeholder)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                onSave(selected ?: custom)
                onDismiss()
            }) { Text(stringResource(R.string.action_save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}

@Composable
private fun Choice(label: String, detail: String?, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected = selected, role = Role.RadioButton, onClick = onSelect),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Column {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
}
