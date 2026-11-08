package com.iaportafolio.argos.data

import android.content.ContentResolver
import androidx.core.net.toUri
import com.iaportafolio.argos.core.keys.ImportedKeyValidation
import java.io.ByteArrayOutputStream
import java.io.IOException

/** Lee un documento elegido con el selector del sistema (SAF). Abstraído para los tests. */
fun interface DocumentReader {
    /** Lee hasta [maxBytes] + 1 bytes (para que el validador detecte «demasiado grande»). */
    suspend fun read(uri: String, maxBytes: Int): ByteArray
}

/**
 * [DocumentReader] con [ContentResolver]. Lee con tope: un archivo enorme elegido por error no
 * se carga entero en memoria (se corta en `maxBytes + 1` y el validador lo rechaza).
 */
class ContentResolverDocumentReader(private val resolver: ContentResolver) : DocumentReader {

    override suspend fun read(uri: String, maxBytes: Int): ByteArray {
        val stream = resolver.openInputStream(uri.toUri())
            ?: throw IOException("No se pudo abrir el archivo elegido.")
        return stream.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(BUFFER_BYTES)
            val limit = maxBytes + 1
            while (out.size() < limit) {
                val read = input.read(buffer, 0, minOf(buffer.size, limit - out.size()))
                if (read < 0) break
                out.write(buffer, 0, read)
            }
            out.toByteArray()
        }
    }

    companion object {
        private const val BUFFER_BYTES = 4096

        /** Tope por defecto para una clave privada. */
        const val KEY_MAX_BYTES = ImportedKeyValidation.MAX_BYTES
    }
}
