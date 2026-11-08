package com.iaportafolio.argos.ui.files

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Vista previa de un archivo (equivale a `FilePreviewScreen` de iOS). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FilePreviewPane(
    preview: FilePreviewState,
    viewModel: RemoteFilesViewModel,
    onClose: () -> Unit,
    onCopyPath: (String) -> Unit,
    showClose: Boolean,
) {
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            // El Scaffold de la pantalla ya aplica el inset de la barra de estado.
            windowInsets = WindowInsets(0),
            title = { Text(preview.name, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
            navigationIcon = {
                IconButton(onClick = onClose) {
                    if (showClose) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.files_preview_close))
                    } else {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                }
            },
            actions = {
                IconButton(onClick = { onCopyPath(preview.path) }) {
                    Icon(painterResource(R.drawable.ic_copy), contentDescription = stringResource(R.string.files_copy_path))
                }
                IconButton(onClick = { viewModel.requestDownload(preview.path, preview.name, preview.size) }) {
                    Icon(painterResource(R.drawable.ic_download), contentDescription = stringResource(R.string.files_download))
                }
            },
        )
        if (preview.isTruncated) TruncatedNotice()
        Box(Modifier.weight(1f)) { PreviewBody(preview, viewModel) }
    }
}

@Composable
private fun TruncatedNotice() {
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.tertiaryContainer).padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            rememberVectorPainter(Icons.Filled.Warning),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onTertiaryContainer,
            modifier = Modifier.padding(end = 8.dp),
        )
        Text(
            stringResource(R.string.files_truncated),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onTertiaryContainer,
        )
    }
}

@Composable
private fun PreviewBody(preview: FilePreviewState, viewModel: RemoteFilesViewModel) {
    val error = preview.error
    val download = { viewModel.requestDownload(preview.path, preview.name, preview.size) }
    when (val content = preview.content) {
        null -> if (error != null) {
            StatusMessage(
                icon = rememberVectorPainter(Icons.Filled.Warning),
                title = stringResource(R.string.files_preview_failed),
                body = error.asString(),
            )
        } else {
            ProgressMessage(stringResource(R.string.files_preview_loading))
        }
        is PreviewContent.Code -> CodeView(content)
        is PreviewContent.Markdown -> SelectionContainer {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
                SafeMarkdown(content.text, Modifier.fillMaxWidth())
            }
        }
        is PreviewContent.Image -> ImageView(content.bytes, onDownload = download)
        PreviewContent.Pdf -> StatusMessage(
            icon = painterResource(R.drawable.ic_pdf),
            title = stringResource(R.string.files_pdf_title),
            body = stringResource(R.string.files_pdf_body),
        ) { DownloadButton(download) }
        PreviewContent.Binary -> StatusMessage(
            icon = painterResource(R.drawable.ic_archive),
            title = stringResource(R.string.files_binary_title),
            body = stringResource(R.string.files_binary_body),
        ) { DownloadButton(download) }
    }
}

@Composable
private fun DownloadButton(onClick: () -> Unit) {
    Button(onClick = onClick) { Text(stringResource(R.string.files_download)) }
}

/** Código con resaltado, una línea por elemento (perezoso) y texto seleccionable. */
@Composable
private fun CodeView(content: PreviewContent.Code) {
    val palette = if (isSystemInDarkTheme()) CodePalette.Dark else CodePalette.Light
    val lines = remember(content, palette) { highlightedLines(content.text, content.tokens, palette) }
    SelectionContainer {
        LazyColumn(
            Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerLow).padding(horizontal = 12.dp),
        ) {
            itemsIndexed(lines) { _, line ->
                Text(line, fontFamily = FontFamily.Monospace, fontSize = CODE_FONT_SIZE, lineHeight = CODE_LINE_HEIGHT)
            }
        }
    }
}

private val CODE_FONT_SIZE = 12.sp
private val CODE_LINE_HEIGHT = 17.sp

/** Imagen decodificada fuera del hilo principal y con muestreo (una foto de 20 MB no revienta la memoria). */
@Composable
private fun ImageView(bytes: ByteArray, onDownload: () -> Unit) {
    val bitmap by produceState<ImageResult>(ImageResult.Loading, bytes) {
        value = withContext(Dispatchers.Default) { decodeSampled(bytes)?.let(ImageResult::Ready) ?: ImageResult.Invalid }
    }
    when (val result = bitmap) {
        ImageResult.Loading -> ProgressMessage(stringResource(R.string.files_preview_loading))
        ImageResult.Invalid -> StatusMessage(
            icon = painterResource(R.drawable.ic_image),
            title = stringResource(R.string.files_image_invalid),
        ) { DownloadButton(onDownload) }
        is ImageResult.Ready -> Image(
            bitmap = result.bitmap.asImageBitmap(),
            contentDescription = stringResource(R.string.files_image_description),
            contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize().padding(16.dp),
        )
    }
}

private sealed interface ImageResult {
    data object Loading : ImageResult
    data object Invalid : ImageResult
    class Ready(val bitmap: Bitmap) : ImageResult
}

private const val MAX_IMAGE_SIDE = 2048

private fun decodeSampled(bytes: ByteArray): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_IMAGE_SIDE) sample *= 2
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
}
