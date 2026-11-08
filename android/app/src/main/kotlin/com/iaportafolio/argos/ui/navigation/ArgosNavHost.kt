package com.iaportafolio.argos.ui.navigation

import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.iaportafolio.argos.AppContainer
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.form.ServerFormScreen
import com.iaportafolio.argos.ui.servers.ServersScreen
import com.iaportafolio.argos.ui.sessions.SessionsScreen
import com.iaportafolio.argos.ui.terminal.TerminalScreen
import kotlinx.serialization.Serializable

/** Rutas tipadas de Navigation Compose. */
@Serializable
data object ServersRoute

@Serializable
data class ServerFormRoute(val serverId: String? = null)

@Serializable
data class SessionsRoute(val serverId: String)

@Serializable
data class TerminalRoute(val serverId: String, val sessionName: String)

/** Ancho a partir del cual se muestran servidores y sesiones lado a lado (tablet / plegable abierto). */
private val TWO_PANE_MIN_WIDTH = 840.dp
private val LIST_PANE_WIDTH = 360.dp

/**
 * Navegación de la app. En móvil, una pila servidores → sesiones (como el iPhone); en pantallas
 * anchas, dos paneles servidores | sesiones (como el `NavigationSplitView` del iPad).
 */
@Composable
fun ArgosNavHost(container: AppContainer) {
    val navController = rememberNavController()
    NavHost(navController = navController, startDestination = ServersRoute) {
        composable<ServersRoute> {
            ServersDestination(
                container = container,
                onAdd = { navController.navigate(ServerFormRoute()) },
                onEdit = { id -> navController.navigate(ServerFormRoute(id)) },
                onOpenSessions = { id -> navController.navigate(SessionsRoute(id)) },
                onOpenTerminal = { id, session -> navController.navigate(TerminalRoute(id, session)) },
            )
        }
        composable<ServerFormRoute> { entry ->
            val route = entry.toRoute<ServerFormRoute>()
            val viewModel = serverFormViewModel(container, route.serverId)
            val state by viewModel.state.collectAsStateWithLifecycle()
            ServerFormScreen(state = state, actions = viewModel, onClose = { navController.popBackStack() })
        }
        composable<SessionsRoute> { entry ->
            val route = entry.toRoute<SessionsRoute>()
            val viewModel = sessionsViewModel(container, route.serverId)
            val state by viewModel.state.collectAsStateWithLifecycle()
            SessionsScreen(
                state = state,
                actions = viewModel,
                onBack = { navController.popBackStack() },
                onOpenSession = { session -> navController.navigate(TerminalRoute(route.serverId, session.name)) },
            )
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
    onOpenSessions: (String) -> Unit,
    onOpenTerminal: (serverId: String, sessionName: String) -> Unit,
) {
    val viewModel = serversViewModel(container)
    val state by viewModel.state.collectAsStateWithLifecycle()
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    // Un servidor borrado deja de estar seleccionado.
    val selected = selectedId?.takeIf { id -> state.servers.any { it.id == id } }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val twoPane = maxWidth >= TWO_PANE_MIN_WIDTH
        val list = @Composable { modifier: Modifier ->
            ServersScreen(
                state = state,
                selectedServerId = if (twoPane) selected else null,
                onAdd = onAdd,
                onOpen = { server -> if (twoPane) selectedId = server.id else onOpenSessions(server.id) },
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
                    val sessions = sessionsViewModel(container, selected)
                    val sessionsState by sessions.state.collectAsStateWithLifecycle()
                    SessionsScreen(
                        state = sessionsState,
                        actions = sessions,
                        onBack = null,
                        onOpenSession = { session -> onOpenTerminal(selected, session.name) },
                    )
                }
            }
        }
    }
}
