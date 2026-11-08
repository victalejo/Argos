package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.Server

/**
 * Acciones de proyecto que piden confirmación antes de ejecutarse (port de
 * `ArgosCore/Projects/ProjectConfirmation.swift`). Textos idénticos a los de Apple.
 */
sealed interface ProjectConfirmation {
    val server: Server

    /** Matar la sesión del proyecto (el proyecto se conserva). */
    data class Stop(override val server: Server, val project: Project) : ProjectConfirmation

    /** Quitar el proyecto de Argos (no toca archivos; la sesión, si corre, sigue viva). */
    data class Remove(override val server: Server, val project: Project) : ProjectConfirmation

    /** Detener todos los proyectos que corren sin estar abiertos en ningún terminal. */
    data class StopBackground(override val server: Server, val projects: List<Project>) : ProjectConfirmation

    val id: String
        get() = when (this) {
            is Stop -> "stop-${project.id}"
            is Remove -> "remove-${project.id}"
            is StopBackground -> "stop-bg-${server.id}"
        }

    val title: String
        get() = when (this) {
            is Stop -> "¿Detener '${project.name}'?"
            is Remove -> "¿Quitar el proyecto '${project.name}'?"
            is StopBackground ->
                "¿Detener ${projects.size} ${if (projects.size == 1) "proyecto" else "proyectos"} en segundo plano?"
        }

    val message: String
        get() = when (this) {
            is Stop -> "Se cerrará su sesión tmux y todo lo que corra en ella (Claude, servidores, builds). " +
                "El proyecto se conserva: al abrirlo de nuevo arranca en la misma carpeta."
            is Remove -> "Solo se quita de Argos. Los archivos del servidor no se tocan y, si su sesión " +
                "está corriendo, sigue viva como sesión suelta."
            is StopBackground -> projects.map { it.name }.sorted().joinToString(", ") +
                "\n\nSe cerrarán sus sesiones para liberar memoria; los proyectos se conservan."
        }

    val actionLabel: String
        get() = when (this) {
            is Stop, is StopBackground -> "Detener"
            is Remove -> "Quitar"
        }
}
