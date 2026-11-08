package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.files.NaturalOrder
import com.iaportafolio.argos.core.tmux.SessionGrouping
import com.iaportafolio.argos.core.tmux.SessionNameValidator
import com.iaportafolio.argos.core.tmux.TmuxSession

/** Un proyecto con su sesión tmux si está corriendo (port de `ProjectEntry`). */
data class ProjectEntry(
    val project: Project,
    /** Sesión viva del proyecto, o `null` si está detenido. */
    val session: TmuxSession?,
) {
    val id: String get() = project.id
    val isRunning: Boolean get() = session != null
}

/** Grupo de proyectos para la barra lateral (port de `ProjectGroup`). */
data class ProjectGroup(val name: String, val entries: List<ProjectEntry>) {
    val id: String get() = name
}

/**
 * Lógica pura que cruza los proyectos guardados con las sesiones tmux vivas (port de
 * `ArgosCore/Projects/ProjectListing.swift`): qué proyectos corren, cuáles están detenidos,
 * qué sesiones no pertenecen a ningún proyecto ("sueltas"), cómo importar sesiones como
 * proyectos y cómo validar cambios.
 *
 * El orden por nombre usa [NaturalOrder], el equivalente de `localizedStandardCompare`.
 */
object ProjectListing {

    /** Resultado de [build]: entradas ordenadas por nombre y sesiones sin proyecto. */
    data class Listing(val entries: List<ProjectEntry>, val looseSessions: List<TmuxSession>)

    /** Cruza proyectos y sesiones. Ante nombres de sesión repetidos gana la primera. */
    fun build(projects: List<Project>, sessions: List<TmuxSession>): Listing {
        val sessionsByName = LinkedHashMap<String, TmuxSession>()
        sessions.forEach { sessionsByName.putIfAbsent(it.name, it) }
        val entries = projects
            .map { ProjectEntry(it, sessionsByName[it.sessionName]) }
            .sortedWith { a, b -> NaturalOrder.compare(a.project.name, b.project.name) }
        val projectSessionNames = projects.mapTo(HashSet()) { it.sessionName }
        val loose = sessions
            .filter { it.name !in projectSessionNames }
            .sortedWith { a, b -> NaturalOrder.compare(a.name, b.name) }
        return Listing(entries, loose)
    }

    /**
     * Agrupa por `group` (sin grupo → [SessionGrouping.UNGROUPED_NAME]); grupos por nombre con
     * "General" al final. Dentro de cada grupo se conserva el orden de [entries].
     */
    fun groups(entries: List<ProjectEntry>): List<ProjectGroup> {
        val grouped = entries.groupBy { entry ->
            entry.project.group?.trimHorizontalWhitespace().orEmpty().ifEmpty { SessionGrouping.UNGROUPED_NAME }
        }
        val order = compareBy<String> { it == SessionGrouping.UNGROUPED_NAME }.then(NaturalOrder)
        return grouped.keys.sortedWith(order).map { ProjectGroup(it, grouped.getValue(it)) }
    }

    /** Candidato de importación: una sesión suelta y la carpeta de su primer panel. */
    fun importCandidate(session: TmuxSession, path: String?): Project? {
        if (path == null || !path.startsWith("/")) return null
        val (group, short) = SessionGrouping.split(session.name)
        // Solo es un grupo real si había "grupo/nombre" con ambas partes; si no, el nombre
        // completo queda como nombre (así `sessionName` sigue coincidiendo con la sesión).
        val hasGroup = short != session.name && session.name == "$group${SessionGrouping.SEPARATOR}$short"
        return Project(
            name = if (hasGroup) short else session.name,
            group = if (hasGroup) group else null,
            path = path,
            startupCommand = null,
        )
    }

    /**
     * Ruta del primer panel (ventana y panel de menor índice) de cada sesión, a partir de la
     * salida de [ProjectCommands.FIRST_PANE_PATHS]
     * (`#{window_index}|#{pane_index}|#{pane_current_path}|#{session_name}`). El nombre de
     * sesión va al final y puede contener '|'. Ante empate gana la primera línea.
     */
    fun firstPanePaths(listPanesOutput: String): Map<String, String> {
        val best = LinkedHashMap<String, PaneCandidate>()
        for (line in listPanesOutput.lines()) {
            val fields = line.split("|", limit = PANE_FIELD_COUNT)
            if (fields.size != PANE_FIELD_COUNT) continue
            val window = fields[0].toIntOrNull() ?: continue
            val pane = fields[1].toIntOrNull() ?: continue
            val session = fields[3].ifEmpty { null } ?: continue
            val current = best[session]
            if (current != null && (current.window < window || (current.window == window && current.pane <= pane))) continue
            best[session] = PaneCandidate(window, pane, fields[2])
        }
        return best.mapValues { it.value.path }
    }

    /**
     * Valida un proyecto nuevo o editado contra los demás del servidor y las sesiones sueltas
     * (el nombre de sesión debe ser único). Devuelve el proyecto normalizado o lanza
     * [SessionNameValidator.ValidationError] / [ProjectError].
     */
    fun validate(project: Project, among: List<Project>, looseSessions: List<TmuxSession>): Project {
        val name = SessionNameValidator.validate(project.name)
        // El '/' separa grupo y nombre en la sesión tmux: no puede ir en el nombre.
        if (SessionGrouping.SEPARATOR in name) {
            throw SessionNameValidator.ValidationError.ForbiddenCharacter(SessionGrouping.SEPARATOR)
        }
        val rawGroup = project.group?.trim().orEmpty()
        val group = if (rawGroup.isEmpty()) {
            null
        } else {
            SessionNameValidator.validate(rawGroup).also {
                if (SessionGrouping.SEPARATOR in rawGroup) {
                    throw SessionNameValidator.ValidationError.ForbiddenCharacter(SessionGrouping.SEPARATOR)
                }
            }
        }
        val path = project.path.trim()
        if (!path.startsWith("/")) throw ProjectError.InvalidPath

        val normalized = project.copy(name = name, group = group, path = path)
        val others = among.filter { it.id != project.id }.map { it.sessionName } + looseSessions.map { it.name }
        if (normalized.sessionName in others) throw ProjectError.DuplicateName(normalized.sessionName)
        return normalized
    }

    private const val PANE_FIELD_COUNT = 4

    private data class PaneCandidate(val window: Int, val pane: Int, val path: String)
}

/** Equivale a `trimmingCharacters(in: .whitespaces)` de Apple: espacios Unicode (Zs) y tabulador. */
internal fun String.trimHorizontalWhitespace(): String =
    trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }
