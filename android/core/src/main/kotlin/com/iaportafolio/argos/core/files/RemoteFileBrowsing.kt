package com.iaportafolio.argos.core.files

import com.iaportafolio.argos.core.agent.RemoteDirectoryListing
import java.io.OutputStream

/**
 * Explorador de archivos de un proyecto por SFTP (port de `ArgosCore/Files/SSHFileBrowser.swift`).
 * Separado de `SSHServicing` igual que `TerminalStreaming`.
 *
 * Todas las operaciones están ACOTADAS a [root] (la carpeta del proyecto): la ruta real, con
 * symlinks resueltos, debe quedar dentro de la real de [root] ([RemotePath.isInside]); si no,
 * lanzan [FileBrowserException.OutsideProject].
 */
interface RemoteFileBrowsing {

    /** Entradas de [path] ordenadas con [RemoteFileEntry.sorted], sin `.`/`..`. */
    suspend fun listRemoteDirectory(path: String, root: String): List<RemoteFileEntry>

    /** Lee hasta [maxBytes] de [path] (por bloques de 256 KiB). */
    suspend fun readRemoteFile(path: String, root: String, maxBytes: Long): RemoteFileContent

    /**
     * Copia [path] entero en [destination] (p. ej. un `content://` elegido con el selector del
     * sistema). Devuelve los bytes escritos. No cierra [destination]. Cancelable entre bloques.
     */
    suspend fun downloadRemoteFile(path: String, root: String, destination: OutputStream): Long

    /** Rutas relativas de los archivos del proyecto para la búsqueda rápida ([FileBrowserCommands]). */
    suspend fun indexProjectFiles(root: String): List<String>

    /**
     * Subcarpetas de [path] para el selector visual de carpeta al crear un proyecto (NO acotado
     * a un proyecto: se navega desde `~`). Port de `listRemoteDirectories(at:)`.
     */
    suspend fun listRemoteDirectories(path: String): RemoteDirectoryListing
}
