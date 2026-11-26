package com.iaportafolio.argos.ui.projects

import com.iaportafolio.argos.core.SessionConnectionState
import com.iaportafolio.argos.core.git.GitRepoSummary
import com.iaportafolio.argos.core.monitor.ServerMemoryPressure
import com.iaportafolio.argos.core.monitor.ServerMemoryPressureLevel
import com.iaportafolio.argos.core.monitor.ServerMemoryReading
import com.iaportafolio.argos.core.monitor.ServerMemoryWarning
import com.iaportafolio.argos.core.usage.ClaudeLimitsStatus
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectConfirmation
import com.iaportafolio.argos.core.projects.ProjectEntry
import com.iaportafolio.argos.core.projects.ProjectListing
import com.iaportafolio.argos.core.projects.ProjectSearch
import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.core.status.ClaudeActivitySnapshot
import com.iaportafolio.argos.core.projects.ProjectStatus
import com.iaportafolio.argos.core.projects.ProjectStatusFilter
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.data.ProjectPreferences
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.sessions.ConnectStep
import com.iaportafolio.argos.ui.sessions.SessionDialog
import com.iaportafolio.argos.ui.sessions.SessionsLoad

/** Importar sesiones sueltas como proyectos (port de `ImportProjectsSheet`). */
data class ImportState(
    val isLoading: Boolean = true,
    val candidates: List<Project> = emptyList(),
    /** Ids de los candidatos marcados. */
    val selected: Set<String> = emptySet(),
    val isImporting: Boolean = false,
    val error: String? = null,
) {
    val canImport: Boolean get() = selected.isNotEmpty() && !isImporting && !isLoading
}

/** Diálogo de proyectos abierto. */
sealed interface ProjectsDialog {
    data class Confirm(val confirmation: ProjectConfirmation, val isSubmitting: Boolean = false) : ProjectsDialog

    data class Form(val form: ProjectFormState) : ProjectsDialog

    data class Import(val state: ImportState) : ProjectsDialog

    /** Arrancar [entry] con el servidor casi sin memoria: se pide confirmación. */
    data class MemoryWarning(val entry: ProjectEntry, val warning: ServerMemoryWarning) : ProjectsDialog
}

/** Evento de una sola vez hacia la navegación. */
sealed interface ProjectsEvent {
    data class OpenProject(val projectId: String) : ProjectsEvent

    data class OpenSession(val sessionName: String) : ProjectsEvent

    /** «Ramas en paralelo» de un proyecto. */
    data class OpenWorktrees(val projectId: String) : ProjectsEvent
}

/** Grupo de la lista con sus entradas ya filtradas. */
data class ProjectSection(val name: String, val entries: List<ProjectEntry>, val isCollapsed: Boolean)

/**
 * Estado de la pantalla de proyectos de un servidor (equivale a `ProjectsView` +
 * `SessionsViewModel+Projects` de Apple). Lo derivado (listado, filtro, grupos colapsados) se
 * calcula con la lógica de `core` al construir cada copia.
 */
data class ProjectsUiState(
    val serverId: String,
    val serverName: String = "",
    val load: SessionsLoad = SessionsLoad.Connecting(ConnectStep.VERIFYING),
    val sessions: List<TmuxSession> = emptyList(),
    val projects: List<Project> = emptyList(),
    /** `projects.json` no se pudo leer: la lista de sesiones sigue visible y se avisa aparte. */
    val projectsError: String? = null,
    /** Resumen git por carpeta de proyecto (insignia ✎/↑/↓); las que no son repo no aparecen. */
    val gitSummaries: Map<String, GitRepoSummary> = emptyMap(),
    val preferences: ProjectPreferences = ProjectPreferences(),
    val isRefreshing: Boolean = false,
    /** Proyecto que se está arrancando (spinner en su fila). */
    val busyProjectId: String? = null,
    val sessionDialog: SessionDialog? = null,
    val dialog: ProjectsDialog? = null,
    val message: UiText? = null,
    /** Estado de Claude Code en las ventanas tmux del servidor (insignias de la lista). */
    val claudeActivity: ClaudeActivitySnapshot = ClaudeActivitySnapshot.EMPTY,
    /** Búsqueda por texto (vacía = sin filtrar). */
    val query: String = "",
    /** Última lectura de memoria del servidor (`null` = aún no hay o no es Linux). */
    val memory: ServerMemoryReading? = null,
    /** Nivel del aviso de memoria (con histéresis respecto al anterior). */
    val memoryLevel: ServerMemoryPressureLevel = ServerMemoryPressureLevel.NORMAL,
    /** Límites de uso de Claude del último sondeo (`null` = sin statusline de Argos o sin datos). */
    val claudeLimits: ClaudeLimitsStatus? = null,
) {
    /** Aviso de memoria que mostrar sobre la lista (`null` = nivel normal). */
    val memoryWarning: ServerMemoryWarning? get() = ServerMemoryPressure.warning(memory, memoryLevel)

    val listing: ProjectListing.Listing = ProjectListing.build(projects, sessions)

    val filter: ProjectStatusFilter get() = preferences.statusFilter

    /** Grupos visibles con el filtro actual (los colapsados conservan la cabecera). */
    val sections: List<ProjectSection> = ProjectListing.groups(
        listing.entries.filter { filter.includes(status(it)) && ProjectSearch.matches(query, it.project) },
    ).map { group ->
        // Buscando, los grupos se abren: si no, un resultado quedaría escondido bajo su cabecera.
        ProjectSection(group.name, group.entries, query.isBlank() && preferences.collapsed.isCollapsed(serverId, group.name))
    }

    val looseSessions: List<TmuxSession> =
        listing.looseSessions.filter { filter.includes(status(it)) && ProjectSearch.matches(query, it) }

    /** Estado de Claude de un proyecto (su sesión) o de un grupo colapsado (el más urgente). */
    fun claude(entry: ProjectEntry): ClaudeActivity? = claudeActivity.activity(entry.project.sessionName)

    fun claude(section: ProjectSection): ClaudeActivity? = claudeActivity.activity(section.entries.map { it.project.sessionName })

    fun claude(session: TmuxSession): ClaudeActivity? = claudeActivity.activity(session.name)

    /** Cuántos proyectos y sesiones caen en cada filtro (etiquetas de los chips). */
    val filterCounts: Map<ProjectStatusFilter, Int> = run {
        val statuses = listing.entries.map(::status) + listing.looseSessions.map(::status)
        ProjectStatusFilter.entries.associateWith { option -> statuses.count(option::includes) }
    }

    val isEmpty: Boolean get() = listing.entries.isEmpty() && listing.looseSessions.isEmpty()

    /** Hay una operación de red de arranque en curso. */
    val isBusy: Boolean get() = load is SessionsLoad.Connecting || isRefreshing

    /** Grupos ya usados por algún proyecto (menú del formulario). */
    val existingGroups: List<String> get() = projects.mapNotNull { it.group?.trim()?.ifEmpty { null } }.distinct().sorted()

    companion object {
        /**
         * Sin registro de terminales abiertos en Android, el estado sale solo de tmux: adjunta
         * → «Segundo plano», sin clientes → «Dormida».
         */
        fun status(entry: ProjectEntry): ProjectStatus =
            ProjectStatus.of(entry.session?.let(::connection), onMac = entry.project.macCheckout != null)

        fun status(session: TmuxSession): ProjectStatus = ProjectStatus.of(connection(session), onMac = false)

        private fun connection(session: TmuxSession) = SessionConnectionState.from(null, session.isAttached)
    }
}
