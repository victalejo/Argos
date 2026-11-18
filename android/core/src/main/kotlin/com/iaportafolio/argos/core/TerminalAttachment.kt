package com.iaportafolio.argos.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Fotos y archivos adjuntados al terminal (port de `ArgosCore/TerminalAttachment.swift`): se suben a
 * una ruta privada del servidor ([SSHServicing.uploadDroppedFile]) y su ruta se escribe en la línea
 * de comandos, como al soltarlos en el Mac.
 */
object TerminalAttachment {

    /** Tope por archivo: se lee entero en memoria antes de subirlo por SFTP. */
    const val MAX_BYTES = 100 * 1024 * 1024

    fun tooLargeMessage(fileName: String): String = "«$fileName» pesa más de ${MAX_BYTES / (1024 * 1024)} MB: súbelo de otra forma."

    private val PHOTO_DATE = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss", Locale.ROOT)

    /** Nombre para una foto sin nombre de archivo: `foto-AAAAMMDD-HHMMSS.ext`. */
    fun photoFileName(fileExtension: String?, date: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String {
        val cleaned = fileExtension.orEmpty().lowercase(Locale.ROOT).filter { it.isLetterOrDigit() }
        return "foto-${PHOTO_DATE.format(date.atZone(zone))}.${cleaned.ifEmpty { "jpg" }}"
    }

    /** Lo que se teclea tras subir: la ruta y un espacio (como iOS). */
    fun typedPath(remotePath: String): String = "$remotePath "

    /** Extensión de un tipo MIME de imagen (`image/png` → `png`), para lo pegado del portapapeles. */
    fun imageExtension(mimeType: String?): String {
        val subtype = mimeType?.substringAfter("image/", missingDelimiterValue = "")?.substringBefore(';')?.trim().orEmpty()
        return when (subtype.lowercase(Locale.ROOT)) {
            "jpeg", "jpg", "pjpeg" -> "jpg"
            "svg+xml" -> "svg"
            "" -> "png"
            else -> subtype.lowercase(Locale.ROOT).filter { it.isLetterOrDigit() }.ifEmpty { "png" }
        }
    }
}
