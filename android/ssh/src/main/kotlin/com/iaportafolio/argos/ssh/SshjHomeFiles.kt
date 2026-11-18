package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.homefile.HomeFileException
import com.iaportafolio.argos.core.homefile.HomeFileExpectation
import com.iaportafolio.argos.core.homefile.HomeFileScripts
import com.iaportafolio.argos.core.homefile.HomeFileWriteOutcome
import com.iaportafolio.argos.core.keys.RemoteHomeFileCommands
import kotlinx.coroutines.CancellationException
import java.util.UUID

/**
 * Ficheros privados en el `$HOME` del servidor (port de `readHomeFile`/`writeHomeFile` de
 * `ArgosCore/RemotePrivateFile.swift`), con el mismo cerrojo y los mismos códigos que el Mac y el
 * iPhone/iPad: `settings.json` de Claude y `projects.json` los escriben todos los dispositivos.
 */
internal class SshjHomeFiles(private val connection: SshjConnection) {

    /** Contenido de `~/<relativePath>`, o `""` si no existe. Un fallo de lectura LANZA. */
    suspend fun read(relativePath: String): String {
        val result = connection.capture(RemoteHomeFileCommands.read(relativePath))
        if (result.exitCode != 0) {
            val detail = result.stderr.trim().ifEmpty { "No se pudo leer ~/$relativePath." }
            throw SSHServiceError.CommandFailed(result.exitCode, detail)
        }
        return result.stdout
    }

    /**
     * Escribe [data] solo si el fichero cumple [expectation] (comprobado bajo el cerrojo, justo
     * antes del `mv`). [HomeFileWriteOutcome.CONFLICT] = no se escribió nada.
     *
     * @throws HomeFileException.Locked si otro dispositivo tiene el cerrojo más de 10 s.
     * @throws HomeFileException.Symlink si el fichero es un enlace simbólico.
     */
    suspend fun write(
        data: ByteArray,
        relativePath: String,
        expectation: HomeFileExpectation,
        backupSuffix: String?,
    ): HomeFileWriteOutcome {
        if (!HomeFileScripts.isSafe(relativePath)) throw HomeFileException.UnsafePath(relativePath)
        val failure = "No se pudo escribir ~/$relativePath."
        val token = UUID.randomUUID().toString().replace("-", "").lowercase()

        // 1) Temporal propio (600) y $HOME para la ruta SFTP absoluta.
        val home = checked(HomeFileScripts.posixShell(HomeFileScripts.prepare(relativePath, token)), failure)
        val temporary = HomeFileScripts.temporaryPath(home, relativePath, token)
            ?: throw SSHServiceError.CommandFailed(0, "No se pudo resolver \$HOME en el servidor.")
        // 2) Contenido por SFTP sobre el temporal.
        try {
            connection.upload(data, temporary, exclusive = false)
        } catch (error: Exception) {
            if (error !is CancellationException) removeQuietly(temporary)
            throw error
        }
        // 3) Cerrojo, comprobación y reemplazo atómico.
        val script = HomeFileScripts.commit(relativePath, token, expectation, backupSuffix)
        val result = connection.capture(HomeFileScripts.posixShell(script))
        return when (result.exitCode) {
            0 -> HomeFileWriteOutcome.WRITTEN
            HomeFileScripts.CONFLICT_EXIT_CODE -> HomeFileWriteOutcome.CONFLICT
            HomeFileScripts.LOCKED_EXIT_CODE -> throw HomeFileException.Locked(relativePath)
            HomeFileScripts.SYMLINK_EXIT_CODE -> throw HomeFileException.Symlink(relativePath)
            else -> throw SSHServiceError.CommandFailed(result.exitCode, result.stderr.trim().ifEmpty { failure })
        }
    }

    private suspend fun checked(command: String, failure: String): String {
        val result = connection.capture(command)
        if (result.exitCode != 0) throw SSHServiceError.CommandFailed(result.exitCode, result.stderr.trim().ifEmpty { failure })
        return result.stdout
    }

    /** Como el `try?` de Apple: el error que importa es el de la subida. */
    private suspend fun removeQuietly(temporary: String) {
        try {
            connection.capture(HomeFileScripts.removeTemporary(temporary))
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            // Lo borrará la limpieza de temporales de más de una hora de la próxima escritura.
        }
    }

    companion object {
        const val BACKUP_SUFFIX = RemoteHomeFileCommands.BACKUP_SUFFIX
    }
}
