package com.iaportafolio.argos.core.files

import com.iaportafolio.argos.core.ShellQuoting
import java.time.Instant

/** Contenido leído de un archivo remoto (port de `RemoteFileContent`). */
class RemoteFileContent(
    val data: ByteArray,
    val size: Long,
    val modified: Instant?,
    /** `true` si el archivo es más grande que lo leído. */
    val isTruncated: Boolean,
) {
    override fun equals(other: Any?): Boolean =
        other is RemoteFileContent && data.contentEquals(other.data) && size == other.size &&
            modified == other.modified && isTruncated == other.isTruncated

    override fun hashCode(): Int =
        listOf(data.contentHashCode(), size, modified, isTruncated).hashCode()
}

/** Errores del explorador (port de `FileBrowserError`). */
sealed class FileBrowserException(message: String) : Exception(message) {
    /** La ruta real (symlinks resueltos) queda fuera de la carpeta del proyecto. */
    class OutsideProject(val path: String) :
        FileBrowserException("'$path' está fuera de la carpeta del proyecto (¿un enlace simbólico?).")
}

/**
 * Parte pura de `ArgosCore/Files/SSHFileBrowser.swift`: el comando del índice de rutas
 * para la búsqueda rápida y el parseo de su salida. El SFTP vive en el módulo de SSH.
 */
object FileBrowserCommands {

    /** Máximo de rutas indexadas para la búsqueda rápida. */
    const val FILE_INDEX_LIMIT = 20_000

    /** Comando del índice: rutas relativas de archivos, saltando carpetas pesadas. */
    fun fileIndexCommand(root: String): String {
        val prune = RemoteFileEntry.NOISY_DIRECTORIES.sorted()
            .joinToString(" -o ") { "-name ${ShellQuoting.singleQuoted(it)}" }
        return "cd ${ShellQuoting.singleQuoted(root)} && find . \\( $prune \\) -prune -o -type f -print " +
            "2>/dev/null | head -n $FILE_INDEX_LIMIT"
    }

    /** Rutas relativas de la salida de [fileIndexCommand] (sin `./` ni líneas vacías). */
    fun parseFileIndex(stdout: String): List<String> =
        stdout.lines()
            .map { it.removePrefix("./") }
            .filter { it.isNotEmpty() }

    /** `true` si una entrada de `readdir` es `.` o `..` (se descartan al listar). */
    fun isDotEntry(name: String): Boolean = name == "." || name == ".."
}
