package com.iaportafolio.argos.ui.files

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.graphics.createBitmap
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * PDF dentro de la app con `PdfRenderer` (antes había que descargarlo): las páginas se pintan
 * perezosamente al ancho de la pantalla. El renderer necesita un descriptor de archivo: se copia a
 * un temporal privado de la caché que se borra al cerrar.
 */
@Composable
internal fun PdfPreview(bytes: ByteArray, onDownload: () -> Unit) {
    val context = LocalContext.current
    val document by produceState<PdfDocument?>(null, bytes) {
        value = withContext(Dispatchers.IO) { PdfDocument.open(context, bytes) } ?: PdfDocument.INVALID
    }
    DisposableEffect(document) { onDispose { document?.close() } }
    when (val opened = document) {
        null -> ProgressMessage(stringResource(R.string.files_preview_loading))
        PdfDocument.INVALID -> StatusMessage(
            icon = painterResource(R.drawable.ic_pdf),
            title = stringResource(R.string.files_pdf_invalid),
        ) { Button(onClick = onDownload) { Text(stringResource(R.string.files_download)) } }
        else -> PdfPages(opened)
    }
}

@Composable
private fun PdfPages(document: PdfDocument) {
    BoxWithConstraints(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerHighest)) {
        val widthPx = with(LocalDensity.current) { maxWidth.roundToPx() }.coerceIn(1, MAX_PAGE_WIDTH_PX)
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(document.pageCount) { index -> PdfPage(document, index, widthPx) }
        }
    }
}

@Composable
private fun PdfPage(document: PdfDocument, index: Int, widthPx: Int) {
    val ratio = document.aspectRatio(index)
    val bitmap by produceState<Bitmap?>(null, document, index, widthPx) { value = document.render(index, widthPx) }
    val description = stringResource(R.string.files_pdf_page, index + 1, document.pageCount)
    Box(Modifier.fillMaxWidth().aspectRatio(ratio).background(PAGE_BACKGROUND), contentAlignment = Alignment.Center) {
        val page = bitmap
        if (page == null) {
            CircularProgressIndicator()
        } else {
            Image(page.asImageBitmap(), contentDescription = description, contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxSize())
        }
    }
}

/** `PdfRenderer` sobre una copia privada; una página a la vez (el renderer no admite concurrencia). */
private class PdfDocument private constructor(
    private val file: File?,
    private val descriptor: ParcelFileDescriptor?,
    private val renderer: PdfRenderer?,
) {
    private val lock = Mutex()
    private val ratios: List<Float> = renderer?.let { r ->
        (0 until r.pageCount).map { index ->
            val page = r.openPage(index)
            try {
                page.width.toFloat() / page.height.coerceAtLeast(1)
            } finally {
                page.close()
            }
        }
    }.orEmpty()

    val pageCount: Int get() = ratios.size

    fun aspectRatio(index: Int): Float = ratios.getOrElse(index) { DEFAULT_RATIO }.coerceIn(MIN_RATIO, MAX_RATIO)

    suspend fun render(index: Int, widthPx: Int): Bitmap? = withContext(Dispatchers.IO) {
        lock.withLock {
            val pdf = renderer ?: return@withLock null
            try {
                val page = pdf.openPage(index)
                try {
                    val height = (widthPx / aspectRatio(index)).toInt().coerceAtLeast(1)
                    createBitmap(widthPx, height).also { bitmap ->
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    }
                } finally {
                    page.close()
                }
            } catch (error: IllegalStateException) {
                // Cerrado mientras se pintaba (se salió del visor): nada que mostrar.
                ArgosLog.warn(ArgosLog.TAG_UI, "Página de PDF sin pintar (${error::class.java.simpleName})")
                null
            }
        }
    }

    /** Espera a la página que se esté pintando: cerrar el renderer con una página abierta lanza. */
    fun close() {
        if (renderer == null) return
        CoroutineScope(Dispatchers.IO).launch { lock.withLock { closeNow() } }
    }

    private fun closeNow() {
        try {
            renderer?.close()
            descriptor?.close()
        } catch (error: IOException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "No se pudo cerrar el PDF", error)
        } catch (error: IllegalStateException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "PDF ya cerrado (${error::class.java.simpleName})")
        } finally {
            file?.delete()
        }
    }

    companion object {
        const val DEFAULT_RATIO = 0.707f
        const val MIN_RATIO = 0.2f
        const val MAX_RATIO = 5f

        val INVALID = PdfDocument(null, null, null)

        /** `null` si no es un PDF que el sistema sepa abrir (dañado, cifrado…). */
        fun open(context: Context, bytes: ByteArray): PdfDocument? {
            val file = File(context.cacheDir, "pdf-${UUID.randomUUID()}.pdf")
            return try {
                file.writeBytes(bytes)
                val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                try {
                    PdfDocument(file, descriptor, PdfRenderer(descriptor))
                } catch (error: IOException) {
                    descriptor.close()
                    throw error
                } catch (error: SecurityException) {
                    descriptor.close()
                    throw error
                }
            } catch (error: IOException) {
                ArgosLog.warn(ArgosLog.TAG_UI, "PDF ilegible", error)
                file.delete()
                null
            } catch (error: SecurityException) {
                // PDF protegido con contraseña.
                ArgosLog.warn(ArgosLog.TAG_UI, "PDF protegido", error)
                file.delete()
                null
            }
        }
    }
}

private const val MAX_PAGE_WIDTH_PX = 2048
private val PAGE_BACKGROUND = androidx.compose.ui.graphics.Color.White
