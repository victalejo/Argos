package com.iaportafolio.argos.ui.navigation

import androidx.navigation.NavController
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.toRoute
import com.iaportafolio.argos.background.ClaudeTarget
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.project.ProjectTab
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** Adónde lleva un aviso de Claude: al proyecto de esa sesión (pestaña Terminal) o a la sesión suelta. */
sealed interface ClaudeDestination {
    data class ProjectTerminal(val serverId: String, val projectId: String) : ClaudeDestination

    data class LooseSession(val serverId: String, val session: String) : ClaudeDestination

    companion object {
        /** Lógica pura: la sesión de un proyecto se llama como él (`grupo/nombre`). */
        fun of(target: ClaudeTarget, projects: List<Project>): ClaudeDestination =
            projects.firstOrNull { it.sessionName == target.session }
                ?.let { ProjectTerminal(target.serverId, it.id) }
                ?: LooseSession(target.serverId, target.session)
    }
}

/**
 * Atiende el toque en un aviso de Claude (como `follow(route)` de iOS): selecciona la ventana en tmux
 * (así el terminal se engancha en ella) y abre el proyecto o la sesión. Lo que falle por el camino
 * (sin red, servidor caído) no impide abrir la sesión: el terminal ya mostrará el error y reintentará.
 */
internal suspend fun NavController.openClaudeWindow(
    target: ClaudeTarget,
    servers: ServerRepository,
    services: ServiceProvider,
    io: CoroutineDispatcher,
) {
    val server = servers.server(target.serverId) ?: return
    val projects = try {
        val service = services.service(server)
        withContext(io) {
            service.selectWindow(target.session, target.window)
            service.loadProjects()
        }
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (error: Exception) {
        ArgosLog.warn(ArgosLog.TAG_UI, "Aviso de Claude: no se pudo preparar la ventana ${target.window} de ${server.endpoint}", error)
        emptyList()
    }
    when (val destination = ClaudeDestination.of(target, projects)) {
        is ClaudeDestination.ProjectTerminal -> {
            val current = currentBackStackEntry?.takeIf { it.destination.hasRoute<ProjectRoute>() }?.toRoute<ProjectRoute>()
            if (current?.serverId != destination.serverId || current.projectId != destination.projectId) {
                navigate(ProjectRoute(destination.serverId, destination.projectId, tab = ProjectTab.TERMINAL.name))
            }
        }
        is ClaudeDestination.LooseSession -> {
            val route = TerminalRoute(destination.serverId, destination.session)
            val current = currentBackStackEntry?.takeIf { it.destination.hasRoute<TerminalRoute>() }?.toRoute<TerminalRoute>()
            if (current != route) navigate(route)
        }
    }
}
