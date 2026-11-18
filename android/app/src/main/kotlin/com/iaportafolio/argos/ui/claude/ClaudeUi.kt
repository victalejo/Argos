package com.iaportafolio.argos.ui.claude

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.ui.common.asString

/** Colores de `ClaudeActivityBadge.swift` (naranja / verde / azul del sistema). */
private val WAITING_TINT = Color(0xFFFF9500)
private val DONE_TINT = Color(0xFF34C759)
private val WORKING_TINT = Color(0xFF0A84FF)

/**
 * Insignia del estado de Claude Code (fila de proyecto o sesión y pestaña de ventana), como
 * `ClaudeActivityBadge` de iOS y Mac: forma y color distintos por estado (se distinguen sin color)
 * y el texto del estado para TalkBack.
 */
@Composable
fun ClaudeActivityBadge(activity: ClaudeActivity, modifier: Modifier = Modifier, size: Dp = 16.dp) {
    val label = activity.label
    val iconModifier = modifier.size(size).semantics { contentDescription = label }
    when (activity) {
        ClaudeActivity.WAITING -> Icon(Icons.Filled.Notifications, contentDescription = null, tint = WAITING_TINT, modifier = iconModifier)
        ClaudeActivity.DONE -> Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = DONE_TINT, modifier = iconModifier)
        ClaudeActivity.WORKING -> Icon(painterResource(R.drawable.ic_claude_working), contentDescription = null, tint = WORKING_TINT, modifier = iconModifier)
    }
}

/** Sugerencia contextual: el servidor tiene Claude Code pero no el indicador. */
@Composable
fun ClaudeHooksHint(onEnable: () -> Unit, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.secondaryContainer)
            .padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(painterResource(R.drawable.ic_sparkles), contentDescription = null, tint = MaterialTheme.colorScheme.onSecondaryContainer)
            Text(
                stringResource(R.string.claude_hooks_hint),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
        }
        Row(Modifier.align(Alignment.End)) {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.claude_hooks_not_now)) }
            TextButton(onClick = onEnable) { Text(stringResource(R.string.claude_hooks_enable)) }
        }
    }
}

/** Confirmación (qué se va a tocar en el servidor) y resultado de «Activar indicador de Claude». */
@Composable
fun ClaudeHooksDialogs(state: ClaudeHooksUiState, viewModel: ClaudeHooksViewModel) {
    if (state.confirming) {
        AlertDialog(
            onDismissRequest = viewModel::cancelInstall,
            title = { Text(stringResource(R.string.claude_hooks_confirm_title, state.serverName)) },
            text = { Text(stringResource(R.string.claude_hooks_confirm_body)) },
            confirmButton = { TextButton(onClick = viewModel::confirmInstall) { Text(stringResource(R.string.claude_hooks_enable)) } },
            dismissButton = { TextButton(onClick = viewModel::cancelInstall) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
    state.result?.let { result ->
        AlertDialog(
            onDismissRequest = viewModel::resultShown,
            title = { Text(stringResource(R.string.claude_hooks_title)) },
            text = { Text(result.asString()) },
            confirmButton = { TextButton(onClick = viewModel::resultShown) { Text(stringResource(R.string.action_close)) } },
        )
    }
}
