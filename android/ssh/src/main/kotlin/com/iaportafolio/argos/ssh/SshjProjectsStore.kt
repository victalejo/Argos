package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.homefile.HomeFileExpectation
import com.iaportafolio.argos.core.homefile.HomeFileWriteOutcome
import com.iaportafolio.argos.core.homefile.PosixChecksum
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectCommands
import com.iaportafolio.argos.core.projects.ProjectError
import com.iaportafolio.argos.core.projects.ProjectsDocument
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap

/**
 * `~/.config/argos/projects.json` del servidor, que reescriben a la vez el Mac, el iPhone/iPad y
 * Android, con el MISMO protocolo que `SSHProjects.swift` + `ProjectsUpdater.swift`:
 *
 * - se lee el archivo y su huella `cksum` se calcula aquí ([PosixChecksum]);
 * - se escribe con [SshjHomeFiles] (cerrojo `projects.json.argos-lock`, temporal propio, copia
 *   `.argos-backup`), y el servidor, con el cerrojo tomado, solo hace el `mv` si la huella sigue
 *   siendo la leída (75 si no; 76 cerrojo ocupado; 77 enlace simbólico);
 * - si otro dispositivo lo cambió, se relee y se reaplica SOLO lo que cambió la app (respecto de lo
 *   último que leyó), hasta [MAX_ATTEMPTS] veces;
 * - se conservan las claves y los proyectos que esta versión no entiende, y con una versión más
 *   nueva NO se reescribe ([ProjectError.UnsupportedVersion]);
 * - sin cambios en los bytes no se escribe;
 * - las escrituras al mismo servidor van de una en una en toda la app ([ServerState.writes]).
 */
internal class SshjProjectsStore(connection: SshjConnection, private val files: SshjHomeFiles) {

    /** Estado compartido por todos los servicios del mismo `host:puerto`. */
    private class ServerState {
        val writes = Mutex()

        /** Lo último leído o escrito: la base sobre la que la app editó su lista. */
        @Volatile
        var lastKnown: List<Project>? = null
    }

    private val state: ServerState = states.computeIfAbsent(connection.endpoint) { ServerState() }

    suspend fun load(): List<Project> {
        val projects = ProjectsDocument.decode(files.read(PATH)).projects
        state.lastKnown = projects
        return projects
    }

    suspend fun save(projects: List<Project>) = state.writes.withLock {
        repeat(MAX_ATTEMPTS) {
            val text = files.read(PATH)
            val current = ProjectsDocument.decode(text)
            current.requireWritable()
            val merged = current.applying(state.lastKnown ?: current.projects, projects)
            val data = merged.encoded()
            if (data.contentEquals(text.toByteArray(Charsets.UTF_8))) {
                state.lastKnown = merged.projects
                return@withLock
            }
            val expectation = HomeFileExpectation.expected(PosixChecksum.expectedFingerprint(text))
            if (files.write(data, PATH, expectation, SshjHomeFiles.BACKUP_SUFFIX) == HomeFileWriteOutcome.WRITTEN) {
                state.lastKnown = merged.projects
                return@withLock
            }
        }
        throw ProjectError.ConcurrentModification
    }

    private companion object {
        val states = ConcurrentHashMap<String, ServerState>()

        const val PATH = ProjectCommands.PROJECTS_RELATIVE_PATH

        /** Releer y reaplicar tantas veces antes de rendirse (`ProjectsUpdater.maxAttempts`). */
        const val MAX_ATTEMPTS = 4
    }
}
