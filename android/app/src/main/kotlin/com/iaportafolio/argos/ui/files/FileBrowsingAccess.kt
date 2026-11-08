package com.iaportafolio.argos.ui.files

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.files.RemoteFileBrowsing
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.toUiText

/** El servicio del servidor no implementa [RemoteFileBrowsing] (implementación antigua o doble). */
class FileBrowsingUnavailableException : Exception("La conexión no admite el explorador de archivos.")

/** El servidor se borró mientras la pantalla estaba abierta. */
class FileServerMissingException : Exception("El servidor ya no existe.")

/**
 * Explorador SFTP del servidor: el mismo servicio de [ServiceProvider] (una conexión por
 * servidor) visto como [RemoteFileBrowsing], igual que el terminal lo ve como
 * `TerminalStreaming`. Lanza [FileBrowsingUnavailableException] si no lo implementa.
 */
internal suspend fun ServiceProvider.fileBrowser(server: Server): RemoteFileBrowsing =
    service(server) as? RemoteFileBrowsing ?: throw FileBrowsingUnavailableException()

/** Texto de UI de un fallo del explorador (los propios con recurso; el resto, su `userMessage`). */
internal fun Throwable.toFilesUiText(): UiText = when (this) {
    is FileBrowsingUnavailableException -> UiText.res(R.string.files_unsupported)
    is FileServerMissingException -> UiText.res(R.string.terminal_server_missing)
    else -> toUiText()
}
