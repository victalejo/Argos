package com.iaportafolio.argos.data

import android.content.ContentResolver
import android.provider.OpenableColumns
import androidx.core.net.toUri

/** Un archivo o foto elegido (selector, portapapeles o «Compartir»): su `content://` y lo que se sabe de él. */
data class PickedAttachment(
    val uri: String,
    /** Nombre visible (`null` = sin nombre, p. ej. una foto o lo pegado). */
    val displayName: String?,
    val mimeType: String?,
    /** Tamaño declarado (`null` = desconocido). */
    val size: Long?,
)

/** Lee lo adjuntado al terminal. Abstraído para los tests. */
interface AttachmentSource {
    /** Nombre, tipo y tamaño del documento (lo que el sistema sepa). */
    fun describe(uri: String): PickedAttachment

    /** Lee hasta [maxBytes] + 1 bytes (si llega a más, es demasiado grande). */
    suspend fun read(uri: String, maxBytes: Int): ByteArray
}

/** [AttachmentSource] con [ContentResolver]; la lectura con tope es la de [ContentResolverDocumentReader]. */
class ContentResolverAttachmentSource(private val resolver: ContentResolver) : AttachmentSource {
    private val reader = ContentResolverDocumentReader(resolver)

    override fun describe(uri: String): PickedAttachment {
        val parsed = uri.toUri()
        var name: String? = null
        var size: Long? = null
        try {
            resolver.query(parsed, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
                }
            }
        } catch (error: RuntimeException) {
            // Proveedores raros (o sin permiso ya): se sube igualmente con un nombre genérico.
            ArgosLog.warn(ArgosLog.TAG_TERMINAL, "No se pudo leer el nombre del adjunto (${error::class.java.simpleName})")
        }
        val type = try {
            resolver.getType(parsed)
        } catch (error: RuntimeException) {
            ArgosLog.warn(ArgosLog.TAG_TERMINAL, "No se pudo leer el tipo del adjunto (${error::class.java.simpleName})")
            null
        }
        return PickedAttachment(uri, name?.takeIf { it.isNotBlank() }, type, size)
    }

    override suspend fun read(uri: String, maxBytes: Int): ByteArray = reader.read(uri, maxBytes)
}
