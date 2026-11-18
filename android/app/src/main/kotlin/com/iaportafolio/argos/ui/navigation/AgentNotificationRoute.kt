package com.iaportafolio.argos.ui.navigation

import androidx.navigation.NavController
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.toRoute
import com.iaportafolio.argos.background.AgentChatTarget
import com.iaportafolio.argos.core.agent.AgentFolderMatch
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.project.ProjectTab
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** Lógica pura: el proyecto cuya carpeta es la del agente (sin barra final), si lo hay. */
internal fun projectForAgent(target: AgentChatTarget, projects: List<Project>): Project? {
    val folder = target.projectPath?.let(AgentFolderMatch::normalized) ?: return null
    return projects.firstOrNull { AgentFolderMatch.normalized(it.path) == folder }
}

/**
 * Atiende el toque en el aviso de un agente persistente (como `followProject` de iOS): si su carpeta
 * es la de un proyecto, abre proyecto → Agentes y encima el chat de ese agente (atrás vuelve a los
 * agentes del proyecto); si no (o sin red), el chat directamente, que ya muestra su propio error.
 * Android no tiene bloqueo propio de la app: no hay nada que desbloquear antes.
 */
internal suspend fun NavController.openAgentChat(
    target: AgentChatTarget,
    servers: ServerRepository,
    services: ServiceProvider,
    io: CoroutineDispatcher,
) {
    val chat = AgentChatRoute(target.serverId, target.agentId)
    val current = currentBackStackEntry?.takeIf { it.destination.hasRoute<AgentChatRoute>() }?.toRoute<AgentChatRoute>()
    if (current == chat) return
    val project = target.projectPath?.let { loadProject(target, servers, services, io) }
    if (project != null) {
        val onProject = currentBackStackEntry?.takeIf { it.destination.hasRoute<ProjectRoute>() }?.toRoute<ProjectRoute>()
        if (onProject?.serverId != target.serverId || onProject.projectId != project.id) {
            navigate(ProjectRoute(target.serverId, project.id, tab = ProjectTab.AGENTS.name))
        }
    }
    navigate(chat)
}

private suspend fun loadProject(
    target: AgentChatTarget,
    servers: ServerRepository,
    services: ServiceProvider,
    io: CoroutineDispatcher,
): Project? {
    val server = servers.server(target.serverId) ?: return null
    return try {
        val projects = withContext(io) { services.service(server).loadProjects() }
        projectForAgent(target, projects)
    } catch (cancel: CancellationException) {
        throw cancel
    } catch (error: Exception) {
        ArgosLog.warn(ArgosLog.TAG_UI, "Aviso de agente: no se pudo leer los proyectos de ${server.endpoint}", error)
        null
    }
}
