package com.iaportafolio.argos.data

import android.content.ContentResolver
import android.provider.DocumentsContract
import androidx.core.net.toUri
import java.io.IOException
import java.io.OutputStream

/** Escribe en un documento elegido con el selector del sistema (SAF). Abstraído para los tests. */
interface DocumentWriter {
    /** Abre [uri] para escribir (truncando), ejecuta [block] y cierra el flujo siempre. */
    suspend fun <T> write(uri: String, block: suspend (OutputStream) -> T): T

    /** Borra el documento (descarga cancelada o fallida: no se deja un archivo a medias). */
    suspend fun delete(uri: String)
}

/** [DocumentWriter] con [ContentResolver]. Llamar desde un dispatcher de E/S. */
class ContentResolverDocumentWriter(private val resolver: ContentResolver) : DocumentWriter {

    override suspend fun <T> write(uri: String, block: suspend (OutputStream) -> T): T {
        val stream = resolver.openOutputStream(uri.toUri(), "wt")
            ?: throw IOException("No se pudo abrir el archivo de destino.")
        return stream.use { block(it) }
    }

    override suspend fun delete(uri: String) {
        if (!DocumentsContract.deleteDocument(resolver, uri.toUri())) {
            throw IOException("No se pudo borrar el archivo a medias.")
        }
    }
}
