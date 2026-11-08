package com.iaportafolio.argos.ui.projects

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.core.agent.RemoteDirectoryListing
import com.iaportafolio.argos.core.files.RemotePath
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.files.FileServerMissingException
import com.iaportafolio.argos.ui.files.fileBrowser
import com.iaportafolio.argos.ui.files.toFilesUiText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class FolderPickerUiState(
    val listing: RemoteDirectoryListing? = null,
    val isLoading: Boolean = false,
    val error: UiText? = null,
) {
    /** Se puede subir un nivel (no en la raíz del sistema). */
    val canGoUp: Boolean get() = listing != null && listing.path != "/"
}

/**
 * Selector visual de carpetas del servidor (port de `RemoteDirectoryPicker` del Mac): navega
 * desde `~` (o la carpeta ya escrita) por `listRemoteDirectories`, que NO está acotado a un
 * proyecto. Crear carpetas desde aquí queda para cuando el contrato lo exponga.
 */
class FolderPickerViewModel(
    private val serverId: String,
    private val repository: ServerRepository,
    private val services: ServiceProvider,
    private val io: CoroutineDispatcher,
) : ViewModel() {

    private val mutableState = MutableStateFlow(FolderPickerUiState())
    val state: StateFlow<FolderPickerUiState> = mutableState.asStateFlow()

    private var job: Job? = null

    /** Abre el selector en [startPath] (vacío o relativo → `~`). */
    fun start(startPath: String) {
        mutableState.value = FolderPickerUiState()
        open(startPath.trim().takeIf { it.startsWith("/") } ?: HOME)
    }

    fun open(path: String) {
        job?.cancel()
        mutableState.update { it.copy(isLoading = true, error = null) }
        job = viewModelScope.launch {
            logFailures(ArgosLog.TAG_SSH, "No se pudo listar carpetas del servidor $serverId") {
                val server = repository.server(serverId) ?: throw FileServerMissingException()
                withContext(io) { services.fileBrowser(server).listRemoteDirectories(path) }
            }.onSuccess { listing -> mutableState.update { it.copy(listing = listing, isLoading = false) } }
                .onFailure { error -> mutableState.update { it.copy(isLoading = false, error = error.toFilesUiText()) } }
        }
    }

    fun openChild(name: String) {
        val base = state.value.listing?.path ?: return
        open(RemotePath.join(base, name))
    }

    fun goUp() {
        val path = state.value.listing?.path ?: return
        open(parent(path))
    }

    /** Reintenta la carpeta actual (o `~` si nunca se llegó a listar ninguna). */
    fun retry() = open(state.value.listing?.path ?: HOME)

    companion object {
        const val HOME = "~"

        /** Carpeta padre de una ruta absoluta (`/` es su propia madre). */
        fun parent(path: String): String {
            val trimmed = path.trimEnd('/')
            val slash = trimmed.lastIndexOf('/')
            return if (slash <= 0) "/" else trimmed.substring(0, slash)
        }
    }
}
