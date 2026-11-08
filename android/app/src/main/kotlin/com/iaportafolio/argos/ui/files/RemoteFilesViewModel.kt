package com.iaportafolio.argos.ui.files

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.FuzzyMatcher
import com.iaportafolio.argos.core.files.FileDownloadStatus
import com.iaportafolio.argos.core.files.FilePreview
import com.iaportafolio.argos.core.files.FilePreviewKind
import com.iaportafolio.argos.core.files.RemoteFileBrowsing
import com.iaportafolio.argos.core.files.RemoteFileContent
import com.iaportafolio.argos.core.files.RemoteFileEntry
import com.iaportafolio.argos.core.files.RemotePath
import com.iaportafolio.argos.core.files.SyntaxHighlighter
import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.DocumentWriter
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Explorador de archivos de UN proyecto (port de `RemoteFilesView` de iOS, solo lectura):
 * navegación acotada a [root], búsqueda rápida sobre el índice, vista previa por tipo
 * ([FilePreview]) y descarga a un documento elegido por el usuario, con progreso y cancelable.
 */
class RemoteFilesViewModel(
    private val serverId: String,
    private val root: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val documents: DocumentWriter,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(FilesUiState(root = root))
    val state: StateFlow<FilesUiState> = mutableState.asStateFlow()

    private val eventChannel = Channel<FilesEvent>(Channel.BUFFERED)
    val events: Flow<FilesEvent> = eventChannel.receiveAsFlow()

    private var listJob: Job? = null
    private var previewJob: Job? = null
    private var searchJob: Job? = null
    private var indexJob: Job? = null
    private var downloadJob: Job? = null

    /** Rutas relativas del proyecto (se indexa una vez por pantalla y al recargar). */
    private var index: List<String>? = null

    init {
        open(root)
    }

    private suspend fun browser(): RemoteFileBrowsing {
        val server = repository.server(serverId) ?: throw FileServerMissingException()
        return services.fileBrowser(server)
    }

    // MARK: - Navegación

    /** Abre la carpeta [path] (ignorada si queda fuera del proyecto). */
    fun open(path: String) {
        if (!RemotePath.isInside(path, root)) return
        listJob?.cancel()
        mutableState.update { it.copy(path = path, entries = emptyList(), load = DirectoryLoad.Loading, isRefreshing = false) }
        listJob = viewModelScope.launch { list(path) }
    }

    fun openEntry(entry: RemoteFileEntry) {
        if (entry.isDirectory) open(entry.path) else openFile(entry.path, entry.name, entry.size)
    }

    /** Atrás: cierra la vista previa, luego la búsqueda y luego sube de carpeta. `false` = salir. */
    fun back(): Boolean {
        val current = state.value
        when {
            current.preview != null -> closePreview()
            current.search.isActive -> closeSearch()
            !current.isAtRoot -> open(FolderParent.of(current.path, root))
            else -> return false
        }
        return true
    }

    fun refresh() {
        if (state.value.isRefreshing) return
        index = null
        val path = state.value.path
        listJob?.cancel()
        mutableState.update { it.copy(isRefreshing = true) }
        listJob = viewModelScope.launch {
            list(path)
            mutableState.update { it.copy(isRefreshing = false) }
        }
    }

    private suspend fun list(path: String) {
        logFailures(ArgosLog.TAG_SSH, "No se pudo listar una carpeta del proyecto en $serverId") {
            withContext(io) { browser().listRemoteDirectory(path, root) }
        }.onSuccess { entries -> mutableState.update { it.copy(entries = entries, load = DirectoryLoad.Loaded) } }
            .onFailure { error ->
                mutableState.update { state ->
                    // Con la lista visible (pull-to-refresh) solo se avisa.
                    if (state.isRefreshing && state.load == DirectoryLoad.Loaded) {
                        state.copy(message = error.toFilesUiText())
                    } else {
                        state.copy(load = DirectoryLoad.Failed(error.toFilesUiText()), entries = emptyList())
                    }
                }
            }
    }

    fun setShowHidden(show: Boolean) = mutableState.update { it.copy(showHidden = show) }

    // MARK: - Búsqueda rápida

    fun openSearch() {
        mutableState.update { it.copy(search = it.search.copy(isActive = true)) }
        if (index == null && indexJob?.isActive != true) indexFiles()
    }

    fun closeSearch() {
        searchJob?.cancel()
        mutableState.update { it.copy(search = FileSearchState()) }
    }

    fun onSearchQuery(query: String) {
        mutableState.update { it.copy(search = it.search.copy(query = query)) }
        rank()
    }

    fun retryIndex() = indexFiles()

    private fun indexFiles() {
        indexJob?.cancel()
        mutableState.update { it.copy(search = it.search.copy(isIndexing = true, error = null)) }
        indexJob = viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo indexar el proyecto en $serverId") {
                withContext(io) { browser().indexProjectFiles(root) }
            }.onSuccess { paths ->
                index = paths
                mutableState.update { it.copy(search = it.search.copy(isIndexing = false)) }
                rank()
            }.onFailure { error ->
                mutableState.update { it.copy(search = it.search.copy(isIndexing = false, error = error.toFilesUiText())) }
            }
        }
    }

    private fun rank() {
        val paths = index ?: return
        val query = state.value.search.query
        searchJob?.cancel()
        searchJob = viewModelScope.launch {
            val results = withContext(io) { FileSearch.rank(query, paths) }
            mutableState.update { it.copy(search = it.search.copy(results = results)) }
        }
    }

    /** Abre la vista previa de un resultado de la búsqueda (ruta relativa a la raíz). */
    fun openSearchResult(relativePath: String) =
        openFile(RemotePath.join(root, relativePath), relativePath.substringAfterLast('/'), size = null)

    // MARK: - Vista previa

    fun openFile(path: String, name: String, size: Long?) {
        if (!RemotePath.isInside(path, root)) return
        previewJob?.cancel()
        mutableState.update { it.copy(preview = FilePreviewState(name = name, path = path, size = size)) }
        previewJob = viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo leer un archivo del proyecto en $serverId") {
                val limit = FilePreview.readLimit(FilePreview.kind(name))
                val file = withContext(io) { browser().readRemoteFile(path, root, limit) }
                file to withContext(io) { prepare(name, file) }
            }.onSuccess { (file, content) ->
                updatePreview(path) { it.copy(content = content, isTruncated = file.isTruncated, size = file.size) }
            }.onFailure { error -> updatePreview(path) { it.copy(error = error.toFilesUiText()) } }
        }
    }

    fun closePreview() {
        previewJob?.cancel()
        mutableState.update { it.copy(preview = null) }
    }

    private fun updatePreview(path: String, change: (FilePreviewState) -> FilePreviewState) = mutableState.update { state ->
        val preview = state.preview
        if (preview == null || preview.path != path) state else state.copy(preview = change(preview))
    }

    // MARK: - Descarga

    /** Pide al usuario dónde guardar [path] (la vista abre `CreateDocument`). */
    fun requestDownload(path: String, name: String, size: Long?) {
        if (downloadJob?.isActive == true) {
            mutableState.update { it.copy(message = UiText.res(R.string.files_download_busy)) }
            return
        }
        eventChannel.trySend(FilesEvent.ChooseDownloadDestination(DownloadRequest(path, name, size)))
    }

    /** El usuario eligió [uri] (o canceló el selector con `null`). */
    fun onDownloadDestination(request: DownloadRequest, uri: String?) {
        if (uri == null || downloadJob?.isActive == true) return
        mutableState.update {
            it.copy(download = DownloadState(request.name, FileDownloadStatus.Downloading(request.name), 0, request.size))
        }
        downloadJob = viewModelScope.launch { download(request, uri) }
    }

    private suspend fun download(request: DownloadRequest, uri: String) {
        try {
            withContext(io) {
                val browser = browser()
                documents.write(uri) { out ->
                    val counting = CountingOutputStream(out) { written -> updateDownload { it.copy(bytesWritten = written) } }
                    browser.downloadRemoteFile(request.path, root, counting).also { counting.flush() }
                }
            }.let { written ->
                updateDownload {
                    it.copy(status = FileDownloadStatus.Saved(uri), bytesWritten = written, totalBytes = it.totalBytes ?: written)
                }
            }
        } catch (cancel: CancellationException) {
            withContext(NonCancellable) { deletePartial(uri) }
            mutableState.update { it.copy(download = null, message = UiText.res(R.string.files_download_cancelled)) }
            throw cancel
        } catch (error: Exception) {
            ArgosLog.error(ArgosLog.TAG_SSH, "Descarga fallida en $serverId", error)
            deletePartial(uri)
            updateDownload { it.copy(status = FileDownloadStatus.Failed(request.name, error.userMessage)) }
        }
    }

    fun cancelDownload() {
        downloadJob?.cancel()
    }

    /** Cierra el banner de una descarga terminada (no cancela una en curso). */
    fun dismissDownload() {
        if (downloadJob?.isActive == true) return
        mutableState.update { it.copy(download = null) }
    }

    private suspend fun deletePartial(uri: String) {
        logFailures(ArgosLog.TAG_STORE, "No se pudo borrar una descarga a medias") {
            withContext(io) { documents.delete(uri) }
        }
    }

    private fun updateDownload(change: (DownloadState) -> DownloadState) = mutableState.update { state ->
        state.download?.let { state.copy(download = change(it)) } ?: state
    }

    // MARK: - Varios

    fun onPathCopied() = mutableState.update { it.copy(message = UiText.res(R.string.files_path_copied)) }

    fun messageShown() = mutableState.update { it.copy(message = null) }

    companion object {
        /** Por encima de esto el código se muestra sin colores (Compose no escala con miles de estilos). */
        const val MAX_UI_HIGHLIGHT = 120_000

        /** Visor definitivo con los bytes leídos (decodifica y resalta fuera del hilo principal). */
        fun prepare(name: String, file: RemoteFileContent): PreviewContent =
            when (val kind = FilePreview.kind(name, file.data)) {
                FilePreviewKind.Markdown -> PreviewContent.Markdown(file.data.toString(Charsets.UTF_8))
                is FilePreviewKind.Code -> {
                    val text = file.data.toString(Charsets.UTF_8)
                    val tokens = if (text.length <= MAX_UI_HIGHLIGHT) SyntaxHighlighter.tokens(text, kind.language) else emptyList()
                    PreviewContent.Code(text, kind.language, tokens)
                }
                FilePreviewKind.Image -> PreviewContent.Image(file.data)
                FilePreviewKind.Pdf -> PreviewContent.Pdf
                FilePreviewKind.Binary -> PreviewContent.Binary
            }
    }
}

/** Ranking de la búsqueda rápida: [FuzzyMatcher] por nombre y ruta; mejores primero. */
object FileSearch {
    const val MAX_RESULTS = 100

    fun rank(query: String, paths: List<String>): List<String> {
        if (query.isBlank()) return emptyList()
        return paths.asSequence()
            .mapNotNull { path ->
                // El nombre pesa más que la carpeta: «page» encuentra antes `page.tsx` que `pages/x`.
                val nameScore = FuzzyMatcher.score(query, path.substringAfterLast('/'))
                val pathScore = FuzzyMatcher.score(query, path)
                val score = maxOf((nameScore ?: -1) * 2, pathScore ?: -1)
                if (score < 0) null else path to score
            }
            .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first.length }.thenBy { it.first })
            .take(MAX_RESULTS)
            .map { it.first }
            .toList()
    }
}

/** Carpeta padre dentro del proyecto (nunca por encima de la raíz). */
object FolderParent {
    fun of(path: String, root: String): String {
        val trimmed = path.trimEnd('/')
        val slash = trimmed.lastIndexOf('/')
        val parent = if (slash <= 0) "/" else trimmed.substring(0, slash)
        return if (RemotePath.isInside(parent, root)) parent else root
    }
}
