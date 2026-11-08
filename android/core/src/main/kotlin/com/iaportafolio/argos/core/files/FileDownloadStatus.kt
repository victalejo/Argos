package com.iaportafolio.argos.core.files

/** Estado de la última descarga del explorador (banner en el visor). */
sealed interface FileDownloadStatus {
    data class Downloading(val name: String) : FileDownloadStatus

    /** [location] es la ruta o URI (`content://…`) donde quedó guardado. */
    data class Saved(val location: String) : FileDownloadStatus

    data class Failed(val name: String, val message: String) : FileDownloadStatus
}
