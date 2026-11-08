package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.agent.AgentExecCommands
import com.iaportafolio.argos.core.agent.RemoteDirectoryListing
import com.iaportafolio.argos.core.files.FileBrowserCommands
import com.iaportafolio.argos.core.files.FileBrowserException
import com.iaportafolio.argos.core.files.RemoteFileBrowsing
import com.iaportafolio.argos.core.files.RemoteFileContent
import com.iaportafolio.argos.core.files.RemoteFileEntry
import com.iaportafolio.argos.core.files.RemotePath
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import net.schmizz.sshj.sftp.FileAttributes
import net.schmizz.sshj.sftp.OpenMode
import net.schmizz.sshj.sftp.RemoteFile
import net.schmizz.sshj.sftp.RemoteResourceInfo
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPClient
import net.schmizz.sshj.sftp.SFTPException
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.time.Instant
import java.util.EnumSet

/**
 * Explorador de archivos por SFTP sobre la conexión compartida (port de
 * `ArgosCore/Files/SSHFileBrowser.swift` y `listRemoteDirectories(at:)` de `SSHAgentExec.swift`).
 *
 * - SOLO LECTURA. Cada ruta se resuelve con `realpath` de SFTP ([SFTPClient.canonicalize]) y se
 *   exige que quede dentro de la real de la raíz ([RemotePath.isInside]): ni `..` ni un symlink
 *   permiten salir del proyecto ([FileBrowserException.OutsideProject]).
 * - Un cliente SFTP por conexión ([SftpClientCache]), compartido por llamadas concurrentes.
 * - Todo lo bloqueante en [Dispatchers.IO] e interrumpible; la cancelación nunca se traduce a
 *   error de SFTP. Los códigos SFTP se traducen a [RemoteFileException].
 */
internal class SshjFileBrowser(private val connection: SshjConnection) : RemoteFileBrowsing {

    private val sftpCache = SftpClientCache(connection)

    override suspend fun listRemoteDirectory(path: String, root: String): List<RemoteFileEntry> =
        withSftp(path) { sftp ->
            val real = containedRealPath(sftp, path, root)
            val infos = blocking { sftp.ls(real) }
            RemoteFileEntry.sorted(
                infos.filterNot { FileBrowserCommands.isDotEntry(it.name) }.map { it.toEntry(parent = path) },
            )
        }

    override suspend fun readRemoteFile(path: String, root: String, maxBytes: Long): RemoteFileContent {
        require(maxBytes >= 0) { "maxBytes no puede ser negativo ($maxBytes)." }
        return withSftp(path) { sftp ->
            val real = containedRealPath(sftp, path, root)
            val attributes = blocking { sftp.stat(real) }
            val size = attributes.sizeOrNull() ?: 0L
            val data = withRemoteFile(sftp, real) { file -> readUpTo(file, minOf(size, maxBytes)) }
            RemoteFileContent(
                data = data,
                size = size,
                modified = attributes.modifiedOrNull(),
                isTruncated = size > data.size,
            )
        }
    }

    override suspend fun downloadRemoteFile(path: String, root: String, destination: OutputStream): Long =
        withSftp(path) { sftp ->
            val real = containedRealPath(sftp, path, root)
            withRemoteFile(sftp, real) { file -> copyTo(file, destination, path) }
        }

    override suspend fun indexProjectFiles(root: String): List<String> =
        FileBrowserCommands.parseFileIndex(connection.capture(FileBrowserCommands.fileIndexCommand(root)).stdout)

    override suspend fun listRemoteDirectories(path: String): RemoteDirectoryListing {
        val result = connection.capture(AgentExecCommands.listRemoteDirectories(path))
        return AgentExecCommands.parseRemoteDirectories(result.stdout)
            ?: throw SSHServiceError.CommandFailed(result.exitCode, "No se pudo abrir el directorio '$path'.")
    }

    /** Cierra el cliente SFTP cacheado (al desconectar el servicio). */
    suspend fun close() = sftpCache.close()

    // MARK: Contención

    /** Ruta real (symlinks resueltos) de [path], comprobando que queda dentro de la real de [root]. */
    private suspend fun containedRealPath(sftp: SFTPClient, path: String, root: String): String {
        val realRoot = blocking { sftp.canonicalize(root) }
        val real = blocking { sftp.canonicalize(path) }
        if (!RemotePath.isInside(real, realRoot)) throw FileBrowserException.OutsideProject(path)
        return real
    }

    // MARK: Lectura por bloques

    /** Hasta [limit] bytes desde el principio, por bloques de [CHUNK_SIZE] (para antes en EOF). */
    private suspend fun readUpTo(file: RemoteFile, limit: Long): ByteArray {
        val capped = minOf(limit, MAX_ARRAY_SIZE)
        val out = ByteArrayOutputStream(minOf(capped, CHUNK_SIZE.toLong()).toInt())
        val chunk = ByteArray(CHUNK_SIZE)
        while (out.size() < capped) {
            val wanted = minOf(capped - out.size(), CHUNK_SIZE.toLong()).toInt()
            val offset = out.size().toLong()
            val read = blocking { file.read(offset, chunk, 0, wanted) }
            if (read <= 0) break
            out.write(chunk, 0, read)
        }
        return out.toByteArray()
    }

    /**
     * Copia el archivo entero en [destination] bloque a bloque: nunca lo carga en memoria y la
     * cancelación se atiende entre bloques (y durante cada petición, por interrupción).
     */
    private suspend fun copyTo(file: RemoteFile, destination: OutputStream, path: String): Long {
        val chunk = ByteArray(CHUNK_SIZE)
        var offset = 0L
        while (true) {
            currentCoroutineContext().ensureActive()
            val read = blocking { file.read(offset, chunk, 0, CHUNK_SIZE) }
            if (read <= 0) break
            try {
                blocking { destination.write(chunk, 0, read) }
            } catch (error: IOException) {
                currentCoroutineContext().ensureActive()
                throw RemoteFileException.DestinationFailed(path, error)
            }
            offset += read
        }
        return offset
    }

    private suspend fun <T> withRemoteFile(sftp: SFTPClient, real: String, block: suspend (RemoteFile) -> T): T {
        val file = blocking { sftp.open(real, EnumSet.of(OpenMode.READ)) }
        try {
            return block(file)
        } finally {
            // Sin interrupción: un CLOSE a medias dejaría el handle abierto en el servidor.
            withContext(NonCancellable + Dispatchers.IO) { closeQuietly(file) }
        }
    }

    // MARK: Errores

    /**
     * Ejecuta [block] con el cliente SFTP cacheado traduciendo los fallos de sshj a
     * [RemoteFileException] (con [path] en el mensaje). Si la coroutine fue cancelada, se
     * relanza la cancelación aunque sshj la haya envuelto en una `IOException`.
     */
    private suspend fun <T> withSftp(path: String, block: suspend (SFTPClient) -> T): T {
        try {
            return block(sftpCache.client())
        } catch (error: SFTPException) {
            currentCoroutineContext().ensureActive()
            throw translate(path, error)
        } catch (error: IOException) {
            currentCoroutineContext().ensureActive()
            throw RemoteFileException.SftpFailed(path, error)
        }
    }

    private fun translate(path: String, error: SFTPException): RemoteFileException = when (error.statusCode) {
        Response.StatusCode.NO_SUCH_FILE, Response.StatusCode.NO_SUCH_PATH -> RemoteFileException.NotFound(path, error)
        Response.StatusCode.PERMISSION_DENIED -> RemoteFileException.PermissionDenied(path, error)
        else -> RemoteFileException.SftpFailed(path, error)
    }

    private fun closeQuietly(file: RemoteFile) {
        try {
            file.close()
        } catch (_: IOException) {
            // El canal SFTP pudo cerrarse ya: el servidor libera el handle al cerrarlo.
        }
    }

    private suspend fun <T> blocking(block: () -> T): T = runInterruptible(Dispatchers.IO, block)

    private companion object {
        /** Los servidores SFTP suelen devolver como mucho ~256 KiB por `read`. */
        const val CHUNK_SIZE = 256 * 1024

        /** Tope práctico de un `ByteArray` en la JVM. */
        const val MAX_ARRAY_SIZE = Int.MAX_VALUE.toLong() - 8

        fun RemoteResourceInfo.toEntry(parent: String): RemoteFileEntry = RemoteFileEntry.fromAttributes(
            name = name,
            parent = parent,
            permissions = attributes.takeIf { it.has(FileAttributes.Flag.MODE) }?.mode?.mask,
            size = attributes.sizeOrNull(),
            modified = attributes.modifiedOrNull(),
        )

        fun FileAttributes.sizeOrNull(): Long? = if (has(FileAttributes.Flag.SIZE)) size else null

        fun FileAttributes.modifiedOrNull(): Instant? =
            if (has(FileAttributes.Flag.ACMODTIME)) Instant.ofEpochSecond(mtime) else null
    }
}
