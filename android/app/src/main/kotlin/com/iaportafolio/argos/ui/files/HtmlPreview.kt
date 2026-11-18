package com.iaportafolio.argos.ui.files

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.files.HtmlPreviewPolicy
import com.iaportafolio.argos.ui.common.ProvideConfirmedLinks
import java.io.ByteArrayInputStream

/**
 * Página HTML del servidor (contenido NO confiable), como el visor del commit Swift c40ab9b:
 * «Vista» renderizada en un `WebView` aislado o «Fuente» resaltada. Por defecto sin JavaScript, sin
 * ninguna petición de red, sin acceso a archivos ni a `content://` y sin navegación propia; los
 * enlaces que pulsa el usuario se abren en el navegador tras confirmar la URL. Un botón permite
 * JavaScript y recursos externos SOLO para esta página (se olvida al cerrarla).
 */
@Composable
internal fun HtmlPreview(content: PreviewContent.Html, path: String, codeView: @Composable (PreviewContent.Code) -> Unit) {
    var showSource by rememberSaveable(path) { mutableStateOf(false) }
    var allowRemote by rememberSaveable(path) { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            SegmentedButton(
                selected = !showSource,
                onClick = { showSource = false },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
            ) { Text(stringResource(R.string.files_html_view)) }
            SegmentedButton(
                selected = showSource,
                onClick = { showSource = true },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
            ) { Text(stringResource(R.string.files_html_source)) }
        }
        if (showSource) {
            codeView(content.source)
            return@Column
        }
        if (!allowRemote) RemoteContentBar(onAllow = { allowRemote = true })
        ProvideConfirmedLinks {
            // Otra instancia al permitir: la configuración del WebView no se relaja en caliente.
            key(allowRemote) { IsolatedWebView(content.html, allowRemote, Modifier.weight(1f)) }
        }
    }
}

@Composable
private fun RemoteContentBar(onAllow: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(start = 16.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            stringResource(R.string.files_html_isolated),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onAllow) { Text(stringResource(R.string.files_html_allow)) }
    }
}

@Composable
private fun IsolatedWebView(html: String, allowRemote: Boolean, modifier: Modifier) {
    val uriHandler = LocalUriHandler.current
    val openExternally by rememberUpdatedState<(String) -> Unit> { url -> uriHandler.openUri(url) }
    Box(modifier.fillMaxWidth()) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context -> isolatedWebView(context, allowRemote) { openExternally(it) }.also { it.load(html) } },
            onRelease = { it.destroy() },
        )
    }
}

private fun WebView.load(html: String) = loadDataWithBaseURL(null, html, "text/html", "utf-8", null)

/** El JavaScript solo se activa si el usuario lo permitió para esta página (lint lo sabe). */
@SuppressLint("SetJavaScriptEnabled")
private fun isolatedWebView(context: Context, allowRemote: Boolean, openExternally: (String) -> Unit): WebView =
    WebView(context).apply {
        settings.apply {
            javaScriptEnabled = allowRemote
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            setGeolocationEnabled(false)
            blockNetworkLoads = !allowRemote
            blockNetworkImage = !allowRemote
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE
            builtInZoomControls = true
            displayZoomControls = false
            loadWithOverviewMode = true
            useWideViewPort = true
            safeBrowsingEnabled = true
        }
        webViewClient = IsolatedClient(allowRemote, openExternally)
    }

/** Aplica [HtmlPreviewPolicy] a cada navegación y a cada recurso. */
private class IsolatedClient(private val allowRemote: Boolean, private val openExternally: (String) -> Unit) : WebViewClient() {

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        val url = request.url?.toString()
        return when (val decision = HtmlPreviewPolicy.decide(url, request.hasGesture(), request.isForMainFrame, allowRemote)) {
            HtmlPreviewPolicy.Decision.Allow -> false
            HtmlPreviewPolicy.Decision.Cancel -> true
            is HtmlPreviewPolicy.Decision.OpenExternally -> {
                openExternally(decision.url)
                true
            }
        }
    }

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
        val url = request.url?.toString()
        if (HtmlPreviewPolicy.allowsResource(url, allowRemote)) return null
        // Sin red: una respuesta vacía en lugar de la petición (imágenes, CSS, fuentes, scripts).
        return WebResourceResponse("text/plain", "utf-8", BLOCKED_STATUS, "Bloqueado", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    }

    private companion object {
        const val BLOCKED_STATUS = 403
    }
}
