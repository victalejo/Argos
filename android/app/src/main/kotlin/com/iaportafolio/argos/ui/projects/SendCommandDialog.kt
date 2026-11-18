package com.iaportafolio.argos.ui.projects

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R

/** «Enviar comando»: lo que se teclea (con Intro) en las sesiones marcadas. */
@Composable
fun SendCommandDialog(state: SendCommandState, viewModel: SendCommandViewModel) {
    AlertDialog(
        onDismissRequest = viewModel::dismiss,
        title = { Text(stringResource(R.string.send_command_title)) },
        text = {
            Column {
                OutlinedTextField(
                    value = state.text,
                    onValueChange = viewModel::onText,
                    singleLine = true,
                    label = { Text(stringResource(R.string.send_command_label)) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !state.isSending,
                )
                state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                LazyColumn(Modifier.heightIn(max = 280.dp)) {
                    items(state.sessions, key = { it }) { session ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .toggleable(value = session in state.selected, role = Role.Checkbox, enabled = !state.isSending) {
                                    viewModel.toggle(session)
                                },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(checked = session in state.selected, onCheckedChange = null)
                            Text(session, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = viewModel::send, enabled = state.canSend) { Text(stringResource(R.string.send_command_send)) }
        },
        dismissButton = { TextButton(onClick = viewModel::dismiss, enabled = !state.isSending) { Text(stringResource(R.string.action_cancel)) } },
    )
}
