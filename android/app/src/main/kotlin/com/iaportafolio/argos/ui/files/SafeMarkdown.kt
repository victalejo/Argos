package com.iaportafolio.argos.ui.files

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.iaportafolio.argos.ui.common.ProvideConfirmedLinks
import com.mikepenz.markdown.m3.Markdown

/**
 * Markdown seguro (equivale a `MarkdownText`/`SafeMarkdownView` de Apple): sin cargador de
 * imágenes (un README podría rastrear al usuario con una imagen remota) y los enlaces solo se
 * abren si [SafeLinkPolicy] los permite, tras confirmar la URL completa.
 */
@Composable
fun SafeMarkdown(text: String, modifier: Modifier = Modifier) {
    ProvideConfirmedLinks {
        // Sin `imageTransformer`: la librería usa NoOpImageTransformerImpl (no descarga nada).
        Markdown(content = text, modifier = modifier)
    }
}
