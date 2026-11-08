package com.iaportafolio.argos.ui.agents

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand.PermissionMode
import com.iaportafolio.argos.data.AgentPermissionSelection

/** Título de un modo (los mismos textos que `AgentPermissionPreferences.swift`). */
@get:StringRes
internal val PermissionMode.titleRes: Int
    get() = when (this) {
        PermissionMode.BYPASS_PERMISSIONS -> R.string.agent_mode_bypass_title
        PermissionMode.ACCEPT_EDITS -> R.string.agent_mode_accept_edits_title
        PermissionMode.DEFAULT -> R.string.agent_mode_default_title
        PermissionMode.PLAN -> R.string.agent_mode_plan_title
    }

@get:StringRes
internal val PermissionMode.detailRes: Int
    get() = when (this) {
        PermissionMode.BYPASS_PERMISSIONS -> R.string.agent_mode_bypass_detail
        PermissionMode.ACCEPT_EDITS -> R.string.agent_mode_accept_edits_detail
        PermissionMode.DEFAULT -> R.string.agent_mode_default_detail
        PermissionMode.PLAN -> R.string.agent_mode_plan_detail
    }

/** Selector de un proyecto (equivale a `AgentPermissionPicker`): el ajuste global o un modo. */
@Composable
internal fun ProjectPermissionDialog(
    selection: AgentPermissionSelection,
    onSelect: (PermissionMode?) -> Unit,
    onDismiss: () -> Unit,
) {
    PermissionDialog(
        title = stringResource(R.string.agents_permissions_label),
        footer = stringResource(R.string.agents_permissions_new_only),
        onDismiss = onDismiss,
    ) {
        PermissionOption(
            title = stringResource(R.string.agents_permissions_use_global, stringResource(selection.global.titleRes)),
            detail = stringResource(R.string.agents_permissions_use_global_detail),
            selected = selection.choice == null,
            onClick = { onSelect(null) },
        )
        PermissionMode.entries.forEach { mode ->
            PermissionOption(
                title = stringResource(mode.titleRes),
                detail = stringResource(mode.detailRes),
                selected = selection.choice == mode,
                onClick = { onSelect(mode) },
            )
        }
    }
}

/** Modo por defecto de todos los proyectos (equivale a `AgentSettingsView`). */
@Composable
fun GlobalPermissionDialog(mode: PermissionMode, onSelect: (PermissionMode) -> Unit, onDismiss: () -> Unit) {
    PermissionDialog(
        title = stringResource(R.string.agents_permissions_global_title),
        footer = stringResource(R.string.agents_permissions_global_footer),
        onDismiss = onDismiss,
    ) {
        PermissionMode.entries.forEach { option ->
            PermissionOption(
                title = stringResource(option.titleRes),
                detail = stringResource(option.detailRes),
                selected = option == mode,
                onClick = { onSelect(option) },
            )
        }
    }
}

@Composable
private fun PermissionDialog(title: String, footer: String, onDismiss: () -> Unit, options: @Composable () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(Modifier.selectableGroup()) { options() }
                Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_close)) } },
    )
}

@Composable
private fun PermissionOption(title: String, detail: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RadioButton(selected = selected, onClick = null)
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Confirmación antes de reanudar en un modo que actúa sin preguntar: `meta.json` no es de fiar. */
@Composable
internal fun ConfirmResumeDialog(mode: PermissionMode, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    val title = stringResource(mode.titleRes)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.agents_resume_confirm_title, title)) },
        text = { Text(stringResource(R.string.agents_resume_confirm_message, stringResource(mode.detailRes))) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.agents_resume_confirm_action, title)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}
