package com.iaportafolio.argos.ui.files

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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.res.stringResource
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog
import com.mikepenz.markdown.m3.Markdown

/**
 * Markdown seguro (equivale a `MarkdownText`/`SafeMarkdownView` de Apple): sin cargador de
 * imágenes (un README podría rastrear al usuario con una imagen remota) y los enlaces solo se
 * abren si [SafeLinkPolicy] los permite, tras confirmar la URL completa.
 */
@Composable
fun SafeMarkdown(text: String, modifier: Modifier = Modifier) {
    val system = LocalUriHandler.current
    var pendingLink by rememberSaveable { mutableStateOf<String?>(null) }
    val guarded = remember {
        object : UriHandler {
            override fun openUri(uri: String) {
                if (SafeLinkPolicy.isAllowed(uri)) pendingLink = uri
            }
        }
    }
    CompositionLocalProvider(LocalUriHandler provides guarded) {
        // Sin `imageTransformer`: la librería usa NoOpImageTransformerImpl (no descarga nada).
        Markdown(content = text, modifier = modifier)
    }
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
