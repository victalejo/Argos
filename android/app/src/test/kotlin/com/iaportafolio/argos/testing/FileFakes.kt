package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.agent.RemoteDirectoryListing
import com.iaportafolio.argos.core.files.FileBrowserException
import com.iaportafolio.argos.core.files.RemoteFileBrowsing
import com.iaportafolio.argos.core.files.RemoteFileContent
import com.iaportafolio.argos.core.files.RemoteFileEntry
import com.iaportafolio.argos.core.files.RemotePath
import com.iaportafolio.argos.data.DocumentWriter
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.yield
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream

fun dir(parent: String, name: String) = RemoteFileEntry(name, RemotePath.join(parent, name), RemoteFileEntry.Kind.DIRECTORY)

fun file(parent: String, name: String, size: Long = 10) =
    RemoteFileEntry(name, RemotePath.join(parent, name), RemoteFileEntry.Kind.FILE, size)

/**
 * [SSHServicing] de tmux/proyectos ([FakeSSHService]) + explorador SFTP en memoria, acotado a
 * la raíz igual que el real.
 */
class FakeFileService(base: FakeSSHService = FakeSSHService()) : SSHServicing by base, RemoteFileBrowsing {
    /** Carpeta → entradas. */
    val directories = mutableMapOf<String, List<RemoteFileEntry>>()

    /** Ruta → contenido completo. */
    val files = mutableMapOf<String, ByteArray>()
    var index: List<String> = emptyList()
    var listError: Exception? = null
    var readError: Exception? = null
    var indexError: Exception? = null
    var downloadError: Exception? = null
    var folders = mutableMapOf<String, RemoteDirectoryListing>()
    var foldersError: Exception? = null

    /** Tamaño de bloque de la descarga simulada. */
    var downloadChunk = 4
    /** Si no es null, la descarga espera aquí tras el primer bloque (para observar progreso/cancelar). */
    var downloadGate: CompletableDeferred<Unit>? = null

    val reads = mutableListOf<Pair<String, Long>>()
    var indexCalls = 0

    private fun checkInside(path: String, root: String) {
        if (!RemotePath.isInside(path, root)) throw FileBrowserException.OutsideProject(path)
    }

    override suspend fun listRemoteDirectory(path: String, root: String): List<RemoteFileEntry> {
        checkInside(path, root)
        listError?.let { throw it }
        return RemoteFileEntry.sorted(directories[path] ?: throw IOException("No existe $path"))
    }

    override suspend fun readRemoteFile(path: String, root: String, maxBytes: Long): RemoteFileContent {
        checkInside(path, root)
        reads += path to maxBytes
        readError?.let { throw it }
        val data = files[path] ?: throw IOException("No existe $path")
        val truncated = data.size > maxBytes
        return RemoteFileContent(if (truncated) data.copyOf(maxBytes.toInt()) else data, data.size.toLong(), null, truncated)
    }

    override suspend fun downloadRemoteFile(path: String, root: String, destination: OutputStream): Long {
        checkInside(path, root)
        downloadError?.let { throw it }
        val data = files[path] ?: throw IOException("No existe $path")
        var written = 0
        while (written < data.size) {
            val len = minOf(downloadChunk, data.size - written)
            destination.write(data, written, len)
            written += len
            downloadGate?.let {
                destination.flush()
                it.await()
            }
            yield()
        }
        return written.toLong()
    }

    override suspend fun indexProjectFiles(root: String): List<String> {
        indexCalls++
        indexError?.let { throw it }
        return index
    }

    override suspend fun listRemoteDirectories(path: String): RemoteDirectoryListing {
        foldersError?.let { throw it }
        return folders[path] ?: throw IOException("No existe $path")
    }
}

class FakeDocumentWriter : DocumentWriter {
    val written = mutableMapOf<String, ByteArray>()
    val deleted = mutableListOf<String>()
    var openError: Exception? = null

    override suspend fun <T> write(uri: String, block: suspend (OutputStream) -> T): T {
        openError?.let { throw it }
        val out = ByteArrayOutputStream()
        return try {
            block(out)
        } finally {
            written[uri] = out.toByteArray()
        }
    }

    override suspend fun delete(uri: String) {
        deleted += uri
        written.remove(uri)
    }
}
