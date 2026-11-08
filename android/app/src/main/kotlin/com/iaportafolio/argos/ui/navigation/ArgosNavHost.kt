package com.iaportafolio.argos.ui.navigation

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.iaportafolio.argos.AppContainer
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.files.FilesScreen
import com.iaportafolio.argos.ui.form.ServerFormScreen
import com.iaportafolio.argos.ui.project.ProjectScreen
import com.iaportafolio.argos.ui.project.WIDE_LAYOUT_MIN_WIDTH
import com.iaportafolio.argos.ui.projects.FolderPickerDialog
import com.iaportafolio.argos.ui.projects.ProjectsEvent
import com.iaportafolio.argos.ui.projects.ProjectsScreen
import com.iaportafolio.argos.ui.servers.ServersScreen
import com.iaportafolio.argos.ui.sessions.SessionsLoad
import com.iaportafolio.argos.ui.terminal.TerminalScreen
import kotlinx.serialization.Serializable

/** Rutas tipadas de Navigation Compose. */
@Serializable
data object ServersRoute

@Serializable
data class ServerFormRoute(val serverId: String? = null)

@Serializable
data class ProjectsRoute(val serverId: String)

@Serializable
data class ProjectRoute(val serverId: String, val projectId: String)

@Serializable
data class TerminalRoute(val serverId: String, val sessionName: String)

private val LIST_PANE_WIDTH = 360.dp

/**
 * Navegación de la app. En móvil, una pila servidores → proyectos → proyecto (como el iPhone);
 * en pantallas anchas, dos paneles servidores | proyectos (como el `NavigationSplitView` del
 * iPad). Las sesiones sueltas abren directamente su terminal.
 */
@Composable
fun ArgosNavHost(container: AppContainer) {
    val navController = rememberNavController()
    val openProject = { serverId: String, projectId: String -> navController.navigate(ProjectRoute(serverId, projectId)) }
    val openTerminal = { serverId: String, session: String -> navController.navigate(TerminalRoute(serverId, session)) }
    NavHost(navController = navController, startDestination = ServersRoute) {
        composable<ServersRoute> {
            ServersDestination(
                container = container,
                onAdd = { navController.navigate(ServerFormRoute()) },
                onEdit = { id -> navController.navigate(ServerFormRoute(id)) },
                onOpenProjects = { id -> navController.navigate(ProjectsRoute(id)) },
                onOpenProject = openProject,
                onOpenTerminal = openTerminal,
            )
        }
        composable<ServerFormRoute> { entry ->
            val route = entry.toRoute<ServerFormRoute>()
            val viewModel = serverFormViewModel(container, route.serverId)
            val state by viewModel.state.collectAsStateWithLifecycle()
            ServerFormScreen(state = state, actions = viewModel, onClose = { navController.popBackStack() })
        }
        composable<ProjectsRoute> { entry ->
            val route = entry.toRoute<ProjectsRoute>()
            ProjectsDestination(
                container = container,
                serverId = route.serverId,
                onBack = { navController.popBackStack() },
                onOpenProject = { openProject(route.serverId, it) },
                onOpenTerminal = { openTerminal(route.serverId, it) },
            )
        }
        composable<ProjectRoute> { entry ->
            val route = entry.toRoute<ProjectRoute>()
            ProjectDestination(container, route.serverId, route.projectId, onBack = { navController.popBackStack() })
        }
        composable<TerminalRoute> { entry ->
            val route = entry.toRoute<TerminalRoute>()
            TerminalScreen(
                viewModel = terminalViewModel(container, route.serverId, route.sessionName),
                onBack = { navController.popBackStack() },
            )
        }
    }
}

@Composable
private fun ServersDestination(
    container: AppContainer,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onOpenProjects: (String) -> Unit,
    onOpenProject: (serverId: String, projectId: String) -> Unit,
    onOpenTerminal: (serverId: String, sessionName: String) -> Unit,
) {
    val viewModel = serversViewModel(container)
    val state by viewModel.state.collectAsStateWithLifecycle()
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    // Un servidor borrado deja de estar seleccionado.
    val selected = selectedId?.takeIf { id -> state.servers.any { it.id == id } }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val twoPane = maxWidth >= WIDE_LAYOUT_MIN_WIDTH
        val list = @Composable { modifier: Modifier ->
            ServersScreen(
                state = state,
                selectedServerId = if (twoPane) selected else null,
                onAdd = onAdd,
                onOpen = { server -> if (twoPane) selectedId = server.id else onOpenProjects(server.id) },
                onEdit = { server -> onEdit(server.id) },
                onRequestDelete = viewModel::requestDelete,
                onConfirmDelete = viewModel::confirmDelete,
                onCancelDelete = viewModel::cancelDelete,
                onForgetHostKey = viewModel::forgetHostKey,
                onMessageShown = viewModel::messageShown,
                modifier = modifier,
            )
        }
        if (!twoPane) {
            list(Modifier.fillMaxSize())
        } else {
            Row(Modifier.fillMaxSize()) {
                list(Modifier.width(LIST_PANE_WIDTH).fillMaxHeight())
                VerticalDivider()
                if (selected == null) {
                    StatusMessage(
                        icon = painterResource(R.drawable.ic_server),
                        title = stringResource(R.string.servers_pick),
                    )
                } else {
                    ProjectsDestination(
                        container = container,
                        serverId = selected,
                        onBack = null,
                        onOpenProject = { onOpenProject(selected, it) },
                        onOpenTerminal = { onOpenTerminal(selected, it) },
                    )
                }
            }
        }
    }
}

@Composable
private fun ProjectsDestination(
    container: AppContainer,
    serverId: String,
    onBack: (() -> Unit)?,
    onOpenProject: (projectId: String) -> Unit,
    onOpenTerminal: (sessionName: String) -> Unit,
) {
    val viewModel = projectsViewModel(container, serverId)
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is ProjectsEvent.OpenProject -> onOpenProject(event.projectId)
                is ProjectsEvent.OpenSession -> onOpenTerminal(event.sessionName)
            }
        }
    }
    // Al volver (p. ej. de un proyecto arrancado desde su pestaña Terminal) se re-lista.
    LifecycleResumeEffect(viewModel) {
        if (viewModel.state.value.load == SessionsLoad.Loaded) viewModel.refresh()
        onPauseOrDispose { }
    }
    val picker = folderPickerViewModel(container, serverId)
    ProjectsScreen(
        state = state,
        actions = viewModel,
        sessionActions = viewModel,
        onBack = onBack,
        folderPicker = { startPath, onPick, onDismiss ->
            val pickerState by picker.state.collectAsStateWithLifecycle()
            LaunchedEffect(Unit) { picker.start(startPath) }
            FolderPickerDialog(
                state = pickerState,
                onOpenChild = picker::openChild,
                onGoUp = picker::goUp,
                onRetry = picker::retry,
                onPick = onPick,
                onDismiss = onDismiss,
            )
        },
    )
}

@Composable
private fun ProjectDestination(container: AppContainer, serverId: String, projectId: String, onBack: () -> Unit) {
    val viewModel = projectViewModel(container, serverId, projectId)
    val state by viewModel.state.collectAsStateWithLifecycle()
    // Al volver a primer plano la sesión pudo detenerse o arrancar desde otro cliente.
    LifecycleResumeEffect(viewModel) {
        viewModel.reload()
        onPauseOrDispose { }
    }
    ProjectScreen(
        state = state,
        viewModel = viewModel,
        onBack = onBack,
        terminal = { project ->
            TerminalScreen(
                viewModel = terminalViewModel(container, serverId, project.sessionName),
                onBack = onBack,
                autoShowKeyboard = false,
            )
        },
        files = { project, twoPane ->
            FilesScreen(viewModel = filesViewModel(container, serverId, project.path), twoPane = twoPane, onExit = onBack)
        },
    )
}
