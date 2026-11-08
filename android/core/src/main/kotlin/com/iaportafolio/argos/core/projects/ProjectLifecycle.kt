package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.tmux.TmuxSession

/**
 * Decisiones puras del ciclo de vida de proyectos (la parte sin estado de
 * `ArgosCore/Projects/SessionsViewModel+Projects.swift`). El ViewModel de Android las combina
 * con `SSHServicing` igual que Apple: lee-modifica-escribe sobre la versión ACTUAL de
 * `projects.json` (otro cliente pudo cambiarla) aplicando las transformaciones de aquí.
 */
object ProjectLifecycle {

    /** Sesión tmux que hay que crear para abrir un proyecto (argumentos de `startProject`). */
    data class StartRequest(val sessionName: String, val path: String, val startupCommand: String?)

    /** Renombrado de sesión tmux que acompaña a una edición. */
    data class SessionRename(val from: String, val to: String)

    /** Resultado de [planSave]: el proyecto validado y, si hace falta, el renombrado previo. */
    data class SavePlan(val project: Project, val rename: SessionRename?)

    /** Proyecto cuya sesión tmux se llama [sessionName]. */
    fun projectForSession(sessionName: String, projects: List<Project>): Project? =
        projects.firstOrNull { it.sessionName == sessionName }

    /**
     * Valida un alta/edición. Si cambia el nombre de sesión de un proyecto en marcha, incluye
     * el renombrado de su sesión tmux para no perderla.
     *
     * @param adoptedSession sesión suelta que se convierte en este proyecto ("Convertir en
     *   proyecto"): su nombre no cuenta como duplicado.
     */
    fun planSave(
        project: Project,
        projects: List<Project>,
        sessions: List<TmuxSession>,
        adoptedSession: String? = null,
    ): SavePlan {
        val loose = ProjectListing.build(projects, sessions).looseSessions.filter { it.name != adoptedSession }
        val validated = ProjectListing.validate(project, projects, loose)
        val previous = projects.firstOrNull { it.id == validated.id }
        val rename = previous
            ?.takeIf { it.sessionName != validated.sessionName && sessions.any { s -> s.name == it.sessionName } }
            ?.let { SessionRename(it.sessionName, validated.sessionName) }
        return SavePlan(validated, rename)
    }

    /** Crea o actualiza (mismo `id`) un proyecto; los nuevos van al final. */
    fun upserting(projects: List<Project>, project: Project): List<Project> =
        if (projects.any { it.id == project.id }) {
            projects.map { if (it.id == project.id) project else it }
        } else {
            projects + project
        }

    /** Quita el proyecto (NUNCA toca archivos ni la sesión: pasa a "sesión suelta"). */
    fun removing(projects: List<Project>, projectId: String): List<Project> =
        projects.filter { it.id != projectId }

    /** Añade los candidatos cuyo nombre de sesión no esté ya en la lista. */
    fun importing(projects: List<Project>, candidates: List<Project>): List<Project> {
        val existing = projects.mapTo(HashSet()) { it.sessionName }
        return projects + candidates.filter { it.sessionName !in existing }
    }

    /** Candidatos de importación para las sesiones sueltas (carpeta = la de su primer panel). */
    fun importCandidates(
        projects: List<Project>,
        sessions: List<TmuxSession>,
        firstPanePaths: Map<String, String>,
    ): List<Project> = ProjectListing.build(projects, sessions).looseSessions.mapNotNull {
        ProjectListing.importCandidate(it, firstPanePaths[it.name])
    }

    /** Marca (o desmarca con `null`) el proyecto como enviado a un Mac. */
    fun settingMacCheckout(projects: List<Project>, projectId: String, checkout: MacCheckout?): List<Project> =
        projects.map { if (it.id == projectId) it.copy(macCheckout = checkout) else it }

    /**
     * Qué hay que crear para abrir el proyecto, o `null` si ya corre (la UI solo tiene que
     * conectarse).
     */
    fun startRequest(project: Project, sessions: List<TmuxSession>, defaultStartupCommand: String): StartRequest? {
        if (sessions.any { it.name == project.sessionName }) return null
        return StartRequest(project.sessionName, project.path, project.resolvedStartupCommand(defaultStartupCommand))
    }
}
