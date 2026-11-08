package com.iaportafolio.argos.ui.files

import com.iaportafolio.argos.core.files.FileDownloadStatus
import com.iaportafolio.argos.core.files.RemoteFileEntry
import com.iaportafolio.argos.core.files.RemotePath
import com.iaportafolio.argos.core.files.SyntaxHighlighter
import com.iaportafolio.argos.ui.common.UiText

/** Una miga de pan: etiqueta visible y carpeta a la que lleva. */
data class Breadcrumb(val label: String, val path: String)

sealed interface DirectoryLoad {
    data object Loading : DirectoryLoad

    data object Loaded : DirectoryLoad

    data class Failed(val message: UiText) : DirectoryLoad
}

/** Contenido ya preparado para el visor (según `FilePreview.kind` con los bytes). */
sealed interface PreviewContent {
    /** Texto/código con sus tokens de resaltado (vacíos si el lenguaje no se conoce o es enorme). */
    data class Code(val text: String, val language: String?, val tokens: List<SyntaxHighlighter.Token>) : PreviewContent

    data class Markdown(val text: String) : PreviewContent

    /** Bytes de la imagen; la vista la decodifica con muestreo (no es `data class`: array). */
    class Image(val bytes: ByteArray) : PreviewContent

    /** PDF: sin visor integrado todavía; se ofrece descargarlo. */
    data object Pdf : PreviewContent

    data object Binary : PreviewContent
}

/** Vista previa abierta de un archivo. */
data class FilePreviewState(
    val name: String,
    val path: String,
    val size: Long? = null,
    val content: PreviewContent? = null,
    /** El archivo es más grande que lo leído: solo se muestra el principio. */
    val isTruncated: Boolean = false,
    val error: UiText? = null,
) {
    val isLoading: Boolean get() = content == null && error == null
}

/** Búsqueda rápida por nombre sobre el índice del proyecto. */
data class FileSearchState(
    val isActive: Boolean = false,
    val query: String = "",
    val isIndexing: Boolean = false,
    val error: UiText? = null,
    /** Rutas RELATIVAS a la raíz, de mejor a peor coincidencia. */
    val results: List<String> = emptyList(),
)

/** Descarga en curso o terminada (banner con progreso). */
data class DownloadState(
    val name: String,
    val status: FileDownloadStatus,
    val bytesWritten: Long = 0,
    val totalBytes: Long? = null,
) {
    /** Progreso 0..1, o `null` si no se conoce el tamaño (indicador indeterminado). */
    val fraction: Float?
        get() = totalBytes?.takeIf { it > 0 }?.let { (bytesWritten.toFloat() / it).coerceIn(0f, 1f) }
}

/** Petición de destino al selector del sistema (`CreateDocument`). */
data class DownloadRequest(val path: String, val name: String, val size: Long?)

sealed interface FilesEvent {
    data class ChooseDownloadDestination(val request: DownloadRequest) : FilesEvent
}

/**
 * Estado del explorador de archivos de un proyecto (port de `RemoteFilesView` de iOS):
 * navegación acotada a [root], vista previa, búsqueda y descarga.
 */
data class FilesUiState(
    val root: String,
    val path: String = root,
    val entries: List<RemoteFileEntry> = emptyList(),
    val load: DirectoryLoad = DirectoryLoad.Loading,
    val showHidden: Boolean = false,
    val isRefreshing: Boolean = false,
    val search: FileSearchState = FileSearchState(),
    val preview: FilePreviewState? = null,
    val download: DownloadState? = null,
    val message: UiText? = null,
) {
    /** Entradas visibles: ocultas y ruidosas fuera salvo que se pidan; carpetas primero y orden natural. */
    val visibleEntries: List<RemoteFileEntry> = RemoteFileEntry.sorted(entries.filter { it.isVisible(showHidden) })

    val hiddenCount: Int get() = entries.size - visibleEntries.size

    val breadcrumbs: List<Breadcrumb> = breadcrumbs(root, path)

    val isAtRoot: Boolean get() = path == root

    companion object {
        fun breadcrumbs(root: String, path: String): List<Breadcrumb> {
            val rootCrumb = Breadcrumb(rootLabel(root), root)
            if (path == root || !RemotePath.isInside(path, root)) return listOf(rootCrumb)
            val parts = RemotePath.relative(path, root).split('/').filter { it.isNotEmpty() }
            val crumbs = parts.runningFold(rootCrumb) { parent, name -> Breadcrumb(name, RemotePath.join(parent.path, name)) }
            return crumbs
        }

        private fun rootLabel(root: String): String = root.trimEnd('/').substringAfterLast('/').ifEmpty { "/" }
    }
}
