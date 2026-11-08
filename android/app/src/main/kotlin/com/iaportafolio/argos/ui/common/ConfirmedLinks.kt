package com.iaportafolio.argos.ui.common

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.res.stringResource
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.ui.files.SafeLinkPolicy

/**
 * Todo enlace que se abra dentro de [content] (vía `LocalUriHandler`) pasa por [SafeLinkPolicy] y
 * se confirma mostrando la URL COMPLETA: el texto de un enlace puede engañar. Los esquemas no
 * permitidos se ignoran sin abrir nada.
 */
@Composable
fun ProvideConfirmedLinks(content: @Composable () -> Unit) {
    val system = LocalUriHandler.current
    var pendingLink by rememberSaveable { mutableStateOf<String?>(null) }
    val guarded = remember {
        object : UriHandler {
            override fun openUri(uri: String) {
                if (SafeLinkPolicy.isAllowed(uri)) pendingLink = uri
            }
        }
    }
    CompositionLocalProvider(LocalUriHandler provides guarded, content = content)
    pendingLink?.let { link ->
        AlertDialog(
            onDismissRequest = { pendingLink = null },
            title = { Text(stringResource(R.string.files_link_title)) },
            text = { Text(link) },
            confirmButton = {
                TextButton(onClick = {
                    pendingLink = null
                    try {
                        system.openUri(link)
                    } catch (error: IllegalArgumentException) {
                        // No hay app para abrirlo: no es un fallo de Argos.
                        ArgosLog.warn(ArgosLog.TAG_UI, "Sin app para abrir un enlace", error)
                    }
                }) { Text(stringResource(R.string.files_link_open)) }
            },
            dismissButton = { TextButton(onClick = { pendingLink = null }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}
