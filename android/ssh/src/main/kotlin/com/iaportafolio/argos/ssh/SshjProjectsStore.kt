package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.keys.RemoteHomeFileCommands
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectCommands
import com.iaportafolio.argos.core.projects.ProjectError
import com.iaportafolio.argos.core.projects.ProjectsDocument
import com.iaportafolio.argos.core.projects.ProjectsFileCommands
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap

/**
 * `~/.config/argos/projects.json` del servidor, que reescriben a la vez el Mac, el iPhone/iPad y
 * Android (ver [ProjectsDocument] y [ProjectsFileCommands]):
 *
 * - se conservan las claves y los proyectos que esta versión no entiende;
 * - si lo escribió una versión más nueva, NO se reescribe ([ProjectError.UnsupportedVersion]);
 * - antes de sustituirlo se comprueba que no cambió desde que se leyó; si cambió, se relee, se
 *   reaplica SOLO lo que cambió la app (respecto de lo último que leyó) y se reintenta;
 * - las escrituras al mismo servidor van de una en una en toda la app ([ServerState.writes]),
 *   aunque haya varios servicios para él.
 */
internal class SshjProjectsStore(private val connection: SshjConnection) {

    /** Estado compartido por todos los servicios del mismo `host:puerto`. */
    private class ServerState {
        val writes = Mutex()

        /** Lo último leído o escrito: la base sobre la que la app editó su lista. */
        @Volatile
        var lastKnown: List<Project>? = null
    }

    private val state: ServerState = states.computeIfAbsent(connection.endpoint) { ServerState() }
    private val writes get() = state.writes
    private var lastKnown: List<Project>?
        get() = state.lastKnown
        set(value) {
            state.lastKnown = value
        }

    suspend fun load(): List<Project> {
        val projects = ProjectsDocument.decode(read().text).projects
        lastKnown = projects
        return projects
    }

    suspend fun save(projects: List<Project>) = writes.withLock {
        repeat(MAX_ATTEMPTS) {
            val snapshot = read()
            val current = ProjectsDocument.decode(snapshot.text)
            current.requireWritable()
            val merged = current.applying(lastKnown ?: current.projects, projects)
            if (replaceIfUnchanged(merged, snapshot.fingerprint)) {
                lastKnown = merged.projects
                return@withLock
            }
        }
        throw ProjectError.ConcurrentModification
    }

    private suspend fun read(): ProjectsFileCommands.Snapshot {
        val result = connection.capture(ProjectsFileCommands.READ_WITH_FINGERPRINT)
        if (result.exitCode != 0) {
            throw SSHServiceError.CommandFailed(result.exitCode, result.stderr.trim().ifEmpty { "No se pudo leer ~/$PATH." })
        }
        return ProjectsFileCommands.parseSnapshot(result.stdout)
            ?: throw SSHServiceError.CommandFailed(0, "Respuesta inesperada al leer ~/$PATH.")
    }

    /** Privado (umask 077), con copia `.argos-backup` y por SFTP. `false` si otro lo cambió. */
    private suspend fun replaceIfUnchanged(document: ProjectsDocument, fingerprint: String): Boolean {
        val failure = "No se pudo escribir ~/$PATH."
        val prepared = connection.capture(RemoteHomeFileCommands.prepareWrite(PATH, backup = true))
        if (prepared.exitCode != 0) throw SSHServiceError.CommandFailed(prepared.exitCode, prepared.stderr.trim().ifEmpty { failure })
        val tempPath = RemoteHomeFileCommands.tempUploadPath(prepared.stdout, PATH)
            ?: throw SSHServiceError.CommandFailed(0, "No se pudo resolver \$HOME en el servidor.")
        connection.upload(document.encoded(), tempPath, exclusive = false)
        val committed = connection.capture(ProjectsFileCommands.commitIfUnchanged(fingerprint))
        return when (committed.exitCode) {
            0 -> true
            ProjectsFileCommands.CHANGED_EXIT_CODE -> false
            else -> throw SSHServiceError.CommandFailed(committed.exitCode, committed.stderr.trim().ifEmpty { failure })
        }
    }

    private companion object {
        val states = ConcurrentHashMap<String, ServerState>()

        const val PATH = ProjectCommands.PROJECTS_RELATIVE_PATH

        /** Releer y reaplicar tantas veces antes de rendirse (otro escribe sin parar). */
        const val MAX_ATTEMPTS = 4
    }
}
