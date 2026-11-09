package com.iaportafolio.argos.ui.form

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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import com.iaportafolio.argos.R
import kotlinx.coroutines.launch

/**
 * Diálogo para pegar la clave privada como texto (más cómodo que crear un archivo en el
 * teléfono). El texto vive en `remember` (no `rememberSaveable`) para que la clave no acabe en
 * el estado guardado de la actividad. Si se trajo del portapapeles, se vacía al usarla.
 */
@Composable
fun PasteKeyDialog(onUse: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var fromClipboard by remember { mutableStateOf(false) }
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.form_key_paste_title)) },
        text = {
            Column {
                Text(stringResource(R.string.form_key_paste_hint), style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it; fromClipboard = false },
                    placeholder = { Text(stringResource(R.string.form_key_paste_placeholder)) },
                    textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    minLines = 6,
                    maxLines = 10,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth(),
                )
                TextButton(onClick = {
                    scope.launch {
                        val pasted = clipboard.getClipEntry()?.clipData
                            ?.takeIf { it.itemCount > 0 }
                            ?.getItemAt(0)?.coerceToText(context)?.toString()
                        if (!pasted.isNullOrBlank()) {
                            text = pasted
                            fromClipboard = true
                        }
                    }
                }) { Text(stringResource(R.string.form_key_paste_from_clipboard)) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = text.isNotBlank(),
                onClick = {
                    onUse(text)
                    if (fromClipboard) scope.launch { clipboard.setClipEntry(null) }
                    onDismiss()
                },
            ) { Text(stringResource(R.string.form_key_paste_use)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}
