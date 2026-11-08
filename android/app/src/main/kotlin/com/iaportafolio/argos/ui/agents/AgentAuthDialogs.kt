package com.iaportafolio.argos.ui.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R

/** No hay sesión de Claude en el servidor: las dos salidas que ofrece el Mac. */
@Composable
internal fun AuthRequiredDialog(serverName: String, onLogin: () -> Unit, onToken: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.agents_auth_title)) },
        text = { Text(stringResource(R.string.agents_auth_body, serverName)) },
        confirmButton = { TextButton(onClick = onLogin) { Text(stringResource(R.string.agents_auth_login)) } },
        dismissButton = { TextButton(onClick = onToken) { Text(stringResource(R.string.agents_auth_token)) } },
    )
}

/**
 * Pegar o borrar el token. El texto vive SOLO en este `remember`: ni en el ViewModel ni en el
 * estado guardado de la actividad, y nunca se puede volver a ver una vez guardado.
 */
@Composable
internal fun TokenDialog(
    hasSavedToken: Boolean,
    error: String?,
    onSave: (String) -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    var token by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.agents_token_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.agents_token_body), style = MaterialTheme.typography.bodyMedium)
                if (hasSavedToken) {
                    Text(stringResource(R.string.agents_token_saved), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
                } else {
                    OutlinedTextField(
                        value = token,
                        onValueChange = { token = it },
                        label = { Text(stringResource(R.string.agents_token_label)) },
                        isError = error != null,
                        supportingText = error?.let { { Text(it) } },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        },
        confirmButton = {
            if (hasSavedToken) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_close)) }
            } else {
                TextButton(onClick = { onSave(token) }, enabled = token.isNotBlank()) { Text(stringResource(R.string.action_save)) }
            }
        },
        dismissButton = {
            if (hasSavedToken) {
                TextButton(onClick = onDelete) { Text(stringResource(R.string.agents_token_delete)) }
            } else {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
            }
        },
    )
}
