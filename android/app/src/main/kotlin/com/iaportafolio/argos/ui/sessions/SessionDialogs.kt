package com.iaportafolio.argos.ui.sessions

import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.tmux.SessionNameValidator

/** Acciones de los diálogos de sesión tmux (crear / renombrar / cerrar). */
interface SessionDialogActions {
    fun dismissDialog()
    fun onDialogTextChange(text: String)
    fun submitDialog()
    fun confirmKill()
}

/** Diálogos de crear / renombrar / cerrar sesión. */
@Composable
internal fun SessionDialogs(dialog: SessionDialog?, actions: SessionDialogActions) {
    when (dialog) {
        is SessionDialog.NameInput -> NameDialog(dialog, actions)
        is SessionDialog.ConfirmKill -> AlertDialog(
            onDismissRequest = actions::dismissDialog,
            title = { Text(stringResource(R.string.sessions_kill_title, dialog.session.name)) },
            text = { Text(stringResource(R.string.sessions_kill_message)) },
            confirmButton = {
                TextButton(onClick = actions::confirmKill) {
                    Text(stringResource(R.string.sessions_kill), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = actions::dismissDialog) { Text(stringResource(R.string.action_cancel)) } },
        )
        null -> Unit
    }
}

@Composable
private fun NameDialog(dialog: SessionDialog.NameInput, actions: SessionDialogActions) {
    val isCreate = dialog is SessionDialog.Create
    val canSubmit = !dialog.isSubmitting && SessionNameValidator.isValid(dialog.text)
    AlertDialog(
        onDismissRequest = actions::dismissDialog,
        title = { Text(stringResource(if (isCreate) R.string.sessions_create_title else R.string.sessions_rename_title)) },
        text = {
            OutlinedTextField(
                value = dialog.text,
                onValueChange = actions::onDialogTextChange,
                label = { Text(stringResource(R.string.sessions_name_label)) },
                isError = dialog.error != null,
                supportingText = { Text(dialog.error ?: stringResource(R.string.sessions_name_hint)) },
                singleLine = true,
                enabled = !dialog.isSubmitting,
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Ascii,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Done,
                ),
                keyboardActions = KeyboardActions(onDone = { if (canSubmit) actions.submitDialog() }),
            )
        },
        confirmButton = {
            TextButton(onClick = actions::submitDialog, enabled = canSubmit) {
                Text(stringResource(if (isCreate) R.string.sessions_create_confirm else R.string.sessions_rename_confirm))
            }
        },
        dismissButton = {
            TextButton(onClick = actions::dismissDialog, enabled = !dialog.isSubmitting) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}
