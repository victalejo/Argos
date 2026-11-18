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
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.iaportafolio.argos.AppContainer
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.AgentChatTarget
import com.iaportafolio.argos.background.CheckTrigger
import com.iaportafolio.argos.background.ClaudeTarget
import com.iaportafolio.argos.ui.claude.ClaudeHooksDialogs
import com.iaportafolio.argos.ui.claude.ClaudeHooksHint
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.ui.about.AboutScreen
import com.iaportafolio.argos.ui.about.LicensesScreen
import com.iaportafolio.argos.ui.agents.AgentChatConnectionEffect
import com.iaportafolio.argos.ui.agents.AgentChatScreen
import com.iaportafolio.argos.ui.agents.AgentListEvent
import com.iaportafolio.argos.ui.agents.AgentListScreen
import com.iaportafolio.argos.ui.agents.AgentLoginScreen
import com.iaportafolio.argos.ui.agents.RequestAgentNotificationPermission
import com.iaportafolio.argos.ui.common.LocalNetworkPermissionPrompt
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.files.FilesScreen
import com.iaportafolio.argos.ui.git.GitChangesScreen
import com.iaportafolio.argos.ui.git.GitHubSection
import com.iaportafolio.argos.ui.projects.WorktreesDialog
import com.iaportafolio.argos.ui.form.ServerFormScreen
import com.iaportafolio.argos.ui.importer.ImportServerScreen
import com.iaportafolio.argos.ui.project.ProjectLoad
import com.iaportafolio.argos.ui.project.ProjectScreen
import com.iaportafolio.argos.ui.project.WIDE_LAYOUT_MIN_WIDTH
import com.iaportafolio.argos.ui.ports.PortForwardRequestPrompt
import com.iaportafolio.argos.ui.ports.PortForwardsScreen
import com.iaportafolio.argos.ui.projects.FolderPickerDialog
import com.iaportafolio.argos.ui.projects.ProjectsEvent
import com.iaportafolio.argos.ui.projects.ProjectsScreen
import com.iaportafolio.argos.ui.servers.BackgroundDiagnosticsDialog
import com.iaportafolio.argos.ui.servers.DiagnosticsInput
import com.iaportafolio.argos.ui.servers.ServersScreen
import com.iaportafolio.argos.ui.sessions.SessionsLoad
import com.iaportafolio.argos.ui.terminal.TerminalConnectionEffect
import com.iaportafolio.argos.ui.terminal.TerminalScreen
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** Rutas tipadas de Navigation Compose. */
@Serializable
data object ServersRoute

@Serializable
data class ServerFormRoute(val serverId: String? = null)

@Serializable
data class ProjectsRoute(val serverId: String)

/** [tab]: pestaña con la que abrir (`ProjectTab.name`; la eligen los avisos de Claude). */
@Serializable
data class ProjectRoute(val serverId: String, val projectId: String, val tab: String? = null)

@Serializable
data class PortsRoute(val serverId: String)

@Serializable
data class TerminalRoute(val serverId: String, val sessionName: String)

@Serializable
data class AgentChatRoute(val serverId: String, val agentId: String)

@Serializable
data class AgentLoginRoute(val serverId: String)

/**
 * «Añadir desde el Mac». Sin argumentos a propósito: el enlace de un deep link lleva la semilla
 * de la clave y no debe acabar en el estado guardado de la navegación (se pasa en memoria).
 */
@Serializable
data object ImportServerRoute

@Serializable
data object AboutRoute

@Serializable
data object LicensesRoute

/** Clave del `savedStateHandle` de [ServersRoute] con el id del servidor recién importado. */
private const val IMPORTED_SERVER_KEY = "importedServerId"

private val LIST_PANE_WIDTH = 360.dp

/**
 * Navegación de la app. En móvil, una pila servidores → proyectos → proyecto (como el iPhone);
 * en pantallas anchas, dos paneles servidores | proyectos (como el `NavigationSplitView` del
 * iPad). Las sesiones sueltas abren directamente su terminal.
 */
@Composable
fun ArgosNavHost(
    container: AppContainer,
    /** Chat que pidió abrir un aviso (ya validado); [onChatTargetConsumed] al navegar. */
    chatTarget: AgentChatTarget? = null,
    onChatTargetConsumed: () -> Unit = {},
    /** Enlace `argos://add-server` de un deep link (ya filtrado); [onImportLinkConsumed] al atenderlo. */
    importLink: String? = null,
    onImportLinkConsumed: () -> Unit = {},
    /** Ventana con Claude que pidió abrir un aviso (ya validada); [onClaudeTargetConsumed] al atenderla. */
    claudeTarget: ClaudeTarget? = null,
    onClaudeTargetConsumed: () -> Unit = {},
) {
    val navController = rememberNavController()
    // Solo en memoria (no `rememberSaveable`): lleva la semilla de la clave.
    var pendingImportLink by remember { mutableStateOf<String?>(null) }
    val openProject = { serverId: String, projectId: String -> navController.navigate(ProjectRoute(serverId, projectId)) }
    val openTerminal = { serverId: String, session: String -> navController.navigate(TerminalRoute(serverId, session)) }
    NavHost(navController = navController, startDestination = ServersRoute) {
        composable<ServersRoute> { entry ->
            val imported by entry.savedStateHandle.getStateFlow<String?>(IMPORTED_SERVER_KEY, null).collectAsStateWithLifecycle()
            ServersDestination(
                container = container,
                importedServerId = imported,
                onImportedServerShown = { entry.savedStateHandle[IMPORTED_SERVER_KEY] = null },
                onAdd = { navController.navigate(ServerFormRoute()) },
                onImport = { navController.navigate(ImportServerRoute) },
                onOpenAbout = { navController.navigate(AboutRoute) },
                onOpenLicenses = { navController.navigate(LicensesRoute) },
                onEdit = { id -> navController.navigate(ServerFormRoute(id)) },
                onOpenProjects = { id -> navController.navigate(ProjectsRoute(id)) },
                onOpenProject = openProject,
                onOpenTerminal = openTerminal,
                onOpenPorts = { id -> navController.navigate(PortsRoute(id)) },
            )
        }
        composable<ServerFormRoute> { entry ->
            val route = entry.toRoute<ServerFormRoute>()
            val viewModel = serverFormViewModel(container, route.serverId)
            val state by viewModel.state.collectAsStateWithLifecycle()
            ServerFormScreen(state = state, actions = viewModel, onClose = { navController.popBackStack() })
        }
        composable<ImportServerRoute> {
            val viewModel = importServerViewModel(container)
            val state by viewModel.state.collectAsStateWithLifecycle()
            LaunchedEffect(pendingImportLink) {
                pendingImportLink?.let {
                    viewModel.onDeepLink(it)
                    pendingImportLink = null
                }
            }
            LaunchedEffect(state.importedServerId) {
                state.importedServerId?.let { id ->
                    viewModel.importHandled()
                    // Como `onImported` de iOS: vuelve a la lista y abre el servidor nuevo.
                    navController.getBackStackEntry<ServersRoute>().savedStateHandle[IMPORTED_SERVER_KEY] = id
                    navController.popBackStack<ServersRoute>(inclusive = false)
                }
            }
            ImportServerScreen(state = state, actions = viewModel, onClose = { navController.popBackStack() })
        }
        composable<AboutRoute> {
            AboutScreen(onBack = { navController.popBackStack() }, onOpenLicenses = { navController.navigate(LicensesRoute) })
        }
        composable<LicensesRoute> {
            LicensesScreen(onBack = { navController.popBackStack() })
        }
        composable<ProjectsRoute> { entry ->
            val route = entry.toRoute<ProjectsRoute>()
            ProjectsDestination(
                container = container,
                serverId = route.serverId,
                onBack = { navController.popBackStack() },
                onOpenProject = { openProject(route.serverId, it) },
                onOpenTerminal = { openTerminal(route.serverId, it) },
                onOpenPorts = { navController.navigate(PortsRoute(route.serverId)) },
            )
        }
        composable<PortsRoute> { entry ->
            val route = entry.toRoute<PortsRoute>()
            val viewModel = portForwardsViewModel(container, route.serverId)
            val state by viewModel.state.collectAsStateWithLifecycle()
            PortForwardsScreen(viewModel = viewModel, state = state, onBack = { navController.popBackStack() })
        }
        composable<ProjectRoute> { entry ->
            val route = entry.toRoute<ProjectRoute>()
            ProjectDestination(
                container = container,
                serverId = route.serverId,
                projectId = route.projectId,
                onBack = { navController.popBackStack() },
                onOpenAgent = { navController.navigate(AgentChatRoute(route.serverId, it)) },
                onOpenLogin = { navController.navigate(AgentLoginRoute(route.serverId)) },
            )
        }
        composable<AgentChatRoute> { entry ->
            val route = entry.toRoute<AgentChatRoute>()
            RequestAgentNotificationPermission(container.agentNotifier)
            AgentChatScreen(
                viewModel = agentChatViewModel(container, route.serverId, route.agentId),
                agentId = route.agentId,
                onBack = { navController.popBackStack() },
                onClosed = { navController.popBackStack() },
            )
        }
        composable<AgentLoginRoute> { entry ->
            val route = entry.toRoute<AgentLoginRoute>()
            val login = agentLoginViewModel(container, route.serverId)
            AgentLoginScreen(
                login = login,
                terminal = agentLoginTerminalViewModel(container, route.serverId, login),
                onClose = { navController.popBackStack() },
            )
        }
        composable<TerminalRoute> { entry ->
            val route = entry.toRoute<TerminalRoute>()
            RequestAgentNotificationPermission(container.agentNotifier, forTerminal = true)
            val terminal = terminalViewModel(container, route.serverId, route.sessionName)
            LocalNetworkPermissionPrompt(container.localNetwork, container.servers.server(route.serverId)?.host, terminal::reconnect)
            TerminalScreen(
                viewModel = terminal,
                onBack = { navController.popBackStack() },
                windows = terminalWindowsViewModel(container, route.serverId, route.sessionName, projectPath = null),
            )
        }
    }
    // Después del NavHost: su grafo ya está puesto al ejecutarse el efecto.
    LaunchedEffect(chatTarget) {
        chatTarget?.let {
            navController.openChat(it)
            onChatTargetConsumed()
        }
    }
    LaunchedEffect(claudeTarget) {
        claudeTarget?.let { target ->
            onClaudeTargetConsumed()
            navController.openClaudeWindow(target, container.servers, container.services, container.io)
        }
    }
    LaunchedEffect(importLink) {
        importLink?.let {
            pendingImportLink = it
            if (navController.currentBackStackEntry?.destination?.hasRoute<ImportServerRoute>() != true) {
                navController.navigate(ImportServerRoute)
            }
            onImportLinkConsumed()
        }
    }
}

/** Abre el chat del aviso, salvo que ya esté delante. */
private fun NavController.openChat(target: AgentChatTarget) {
    val route = AgentChatRoute(target.serverId, target.agentId)
    val current = currentBackStackEntry?.takeIf { it.destination.hasRoute<AgentChatRoute>() }?.toRoute<AgentChatRoute>()
    if (current != route) navigate(route)
}

@Composable
private fun ServersDestination(
    container: AppContainer,
    importedServerId: String?,
    onImportedServerShown: () -> Unit,
    onAdd: () -> Unit,
    onImport: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenLicenses: () -> Unit,
    onEdit: (String) -> Unit,
    onOpenProjects: (String) -> Unit,
    onOpenProject: (serverId: String, projectId: String) -> Unit,
    onOpenTerminal: (serverId: String, sessionName: String) -> Unit,
    onOpenPorts: (serverId: String) -> Unit,
) {
    val viewModel = serversViewModel(container)
    val state by viewModel.state.collectAsStateWithLifecycle()
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var claudeHooksFor by rememberSaveable { mutableStateOf<String?>(null) }
    claudeHooksFor?.let { id -> ClaudeHooksHost(container, id, onDone = { claudeHooksFor = null }) }
    // Un servidor borrado deja de estar seleccionado.
    val selected = selectedId?.takeIf { id -> state.servers.any { it.id == id } }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val twoPane = maxWidth >= WIDE_LAYOUT_MIN_WIDTH
        // Recién importado desde el Mac: se abre (en tablet, se selecciona).
        LaunchedEffect(importedServerId) {
            importedServerId?.let { id ->
                onImportedServerShown()
                if (twoPane) selectedId = id else onOpenProjects(id)
            }
        }
        val list = @Composable { modifier: Modifier ->
            ServersScreen(
                state = state,
                selectedServerId = if (twoPane) selected else null,
                onAdd = onAdd,
                onImport = onImport,
                onOpenAbout = onOpenAbout,
                onOpenLicenses = onOpenLicenses,
                onOpen = { server -> if (twoPane) selectedId = server.id else onOpenProjects(server.id) },
                onEdit = { server -> onEdit(server.id) },
                onRequestDelete = viewModel::requestDelete,
                onConfirmDelete = viewModel::confirmDelete,
                onCancelDelete = viewModel::cancelDelete,
                onForgetHostKey = viewModel::forgetHostKey,
                onAgentPermissionModeChange = viewModel::setAgentPermissionMode,
                onAgentNotificationsChange = viewModel::setAgentNotificationsEnabled,
                onKeepTerminalAliveChange = viewModel::setKeepTerminalAlive,
                onMessageShown = viewModel::messageShown,
                modifier = modifier,
                diagnostics = { onDismiss -> DiagnosticsDestination(container, onDismiss) },
                onEnableClaude = { server -> claudeHooksFor = server.id },
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
                        onOpenPorts = { onOpenPorts(selected) },
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
    onOpenPorts: () -> Unit,
) {
    val viewModel = projectsViewModel(container, serverId)
    val state by viewModel.state.collectAsStateWithLifecycle()
    LocalNetworkPermissionPrompt(container.localNetwork, container.servers.server(serverId)?.host, viewModel::refresh)
    var worktreesFor by rememberSaveable { mutableStateOf<String?>(null) }
    worktreesFor?.let { projectId ->
        WorktreesDialog(worktreesViewModel(container, serverId, projectId)) {
            worktreesFor = null
            viewModel.refresh()
        }
    }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is ProjectsEvent.OpenProject -> onOpenProject(event.projectId)
                is ProjectsEvent.OpenSession -> onOpenTerminal(event.sessionName)
                is ProjectsEvent.OpenWorktrees -> worktreesFor = event.projectId
            }
        }
    }
    // Al volver (p. ej. de un proyecto arrancado desde su pestaña Terminal) se re-lista.
    LifecycleResumeEffect(viewModel) {
        if (viewModel.state.value.load == SessionsLoad.Loaded) viewModel.refresh()
        onPauseOrDispose { }
    }
    val picker = folderPickerViewModel(container, serverId)
    val hooks = claudeHooksViewModel(container, serverId)
    val hooksState by hooks.state.collectAsStateWithLifecycle()
    // Con la conexión ya abierta: ¿tiene Claude pero no el indicador?
    LaunchedEffect(hooks, state.load) { if (state.load == SessionsLoad.Loaded) hooks.checkHint() }
    ClaudeHooksDialogs(hooksState, hooks)
    ProjectsScreen(
        state = state,
        actions = viewModel,
        sessionActions = viewModel,
        onBack = onBack,
        onOpenPorts = onOpenPorts,
        onEnableClaude = hooks::requestInstall,
        claudeHint = { if (hooksState.showHint) ClaudeHooksHint(onEnable = hooks::requestInstall, onDismiss = hooks::dismissHint) },
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
private fun ProjectDestination(
    container: AppContainer,
    serverId: String,
    projectId: String,
    onBack: () -> Unit,
    onOpenAgent: (String) -> Unit,
    onOpenLogin: () -> Unit,
) {
    val viewModel = projectViewModel(container, serverId, projectId)
    val state by viewModel.state.collectAsStateWithLifecycle()
    LocalNetworkPermissionPrompt(container.localNetwork, container.servers.server(serverId)?.host, viewModel::reload)
    // Al volver a primer plano la sesión pudo detenerse o arrancar desde otro cliente.
    LifecycleResumeEffect(viewModel) {
        viewModel.reload()
        onPauseOrDispose { }
    }
    // Chat abierto junto a la lista (pantallas anchas): aquí para seguir conectado en otras pestañas.
    var selectedAgentId by rememberSaveable(projectId) { mutableStateOf<String?>(null) }
    val isRunning = (state.load as? ProjectLoad.Loaded)?.isRunning == true
    // «Claude quiere mostrarte el puerto N»: solo se abre si el usuario acepta.
    PortForwardRequestPrompt(portForwardRequestsViewModel(container, serverId))
    ProjectScreen(
        state = state,
        viewModel = viewModel,
        onBack = onBack,
        terminal = { project ->
            RequestAgentNotificationPermission(container.agentNotifier, forTerminal = true)
            TerminalScreen(
                viewModel = terminalViewModel(container, serverId, project.sessionName),
                onBack = onBack,
                autoShowKeyboard = false,
                windows = terminalWindowsViewModel(container, serverId, project.sessionName, project.path),
                ownsConnection = false,
            )
        },
        files = { project, twoPane ->
            FilesScreen(viewModel = filesViewModel(container, serverId, project.path), twoPane = twoPane, onExit = onBack)
        },
        changes = { project, twoPane ->
            GitChangesScreen(
                viewModel = gitChangesViewModel(container, serverId, project.path, project.name),
                twoPane = twoPane,
                onExit = onBack,
                gitHub = { root, branch -> GitHubSection(gitHubViewModel(container, serverId, root, project.name), branch) },
            )
        },
        agents = { project, twoPane ->
            AgentsDestination(
                container,
                serverId,
                project,
                twoPane,
                selectedAgentId = selectedAgentId,
                onSelectAgent = { selectedAgentId = it },
                onBack,
                onOpenAgent,
                onOpenLogin,
            )
        },
        // Como el Mac (c131ba1): el terminal y el chat siguen enganchados mientras el proyecto esté
        // abierto; cambiar de pestaña ya no hace detach ni repite el handshake.
        keepAlive = { project, twoPane ->
            if (isRunning && state.terminalOpened) {
                TerminalConnectionEffect(terminalViewModel(container, serverId, project.sessionName))
            }
            val chatId = selectedAgentId
            if (twoPane && chatId != null) AgentChatConnectionEffect(agentChatViewModel(container, serverId, chatId))
        },
    )
}

/** En móvil la lista abre el chat a pantalla completa; en pantallas anchas, lista y chat lado a lado. */
@Composable
private fun AgentsDestination(
    container: AppContainer,
    serverId: String,
    project: Project,
    twoPane: Boolean,
    /** Chat seleccionado en pantallas anchas (lo guarda la pantalla del proyecto). */
    selectedAgentId: String?,
    onSelectAgent: (String?) -> Unit,
    onBack: () -> Unit,
    onOpenAgent: (String) -> Unit,
    onOpenLogin: () -> Unit,
) {
    val viewModel = agentListViewModel(container, serverId, project.name, project.path)
    val selectedId = selectedAgentId
    val currentTwoPane by rememberUpdatedState(twoPane)
    val currentOnSelect by rememberUpdatedState(onSelectAgent)
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is AgentListEvent.OpenAgent -> if (currentTwoPane) currentOnSelect(event.agentId) else onOpenAgent(event.agentId)
                AgentListEvent.OpenLogin -> onOpenLogin()
            }
        }
    }
    // Al volver del chat o del login: un agente pudo cambiar y la sesión de Claude, abrirse.
    LifecycleResumeEffect(viewModel) {
        viewModel.refresh()
        onPauseOrDispose { }
    }
    val list = @Composable { modifier: Modifier ->
        AgentListScreen(
            viewModel = viewModel,
            selectedAgentId = if (twoPane) selectedId else null,
            onBack = onBack,
            modifier = modifier,
        )
    }
    if (!twoPane) {
        list(Modifier.fillMaxSize())
        return
    }
    Row(Modifier.fillMaxSize()) {
        list(Modifier.width(LIST_PANE_WIDTH).fillMaxHeight())
        VerticalDivider()
        val agentId = selectedId
        if (agentId == null) {
            StatusMessage(
                icon = painterResource(R.drawable.ic_sparkles),
                title = stringResource(R.string.agents_pick),
            )
        } else {
            RequestAgentNotificationPermission(container.agentNotifier)
            val chat = agentChatViewModel(container, serverId, agentId)
            val isAlive by remember(chat) { chat.state.map { it.isAlive }.distinctUntilChanged() }.collectAsStateWithLifecycle(initialValue = null)
            // La lista refleja lo que se pare o reanude desde el chat de al lado.
            LaunchedEffect(chat, isAlive) { if (isAlive != null) viewModel.refresh() }
            AgentChatScreen(
                viewModel = chat,
                agentId = agentId,
                onBack = null,
                onClosed = {
                    onSelectAgent(null)
                    viewModel.refresh()
                },
                ownsConnection = false,
            )
        }
    }
}

/** «Activar indicador de Claude» pedido desde el menú de un servidor: confirma, instala y avisa. */
@Composable
private fun ClaudeHooksHost(container: AppContainer, serverId: String, onDone: () -> Unit) {
    val hooks = claudeHooksViewModel(container, serverId)
    val state by hooks.state.collectAsStateWithLifecycle()
    var asked by rememberSaveable(serverId) { mutableStateOf(false) }
    LaunchedEffect(hooks) {
        if (!asked) {
            asked = true
            hooks.requestInstall()
        }
    }
    ClaudeHooksDialogs(state, hooks)
    // Cerrado el diálogo (cancelado o con el resultado ya leído), se suelta.
    if (asked && !state.confirming && !state.isInstalling && state.result == null) LaunchedEffect(Unit) { onDone() }
}

/** Diagnóstico de avisos (Ajustes → Avisos y segundo plano). */
@Composable
private fun DiagnosticsDestination(container: AppContainer, onDismiss: () -> Unit) {
    val lastCheck by container.diagnostics.lastCheck.collectAsStateWithLifecycle()
    val ciCount by container.ciWatches.watchCountFlow.collectAsStateWithLifecycle()
    val enabled by container.agentNotifier.notificationsEnabled.collectAsStateWithLifecycle()
    var checking by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    BackgroundDiagnosticsDialog(
        input = DiagnosticsInput(
            lastCheck = lastCheck,
            ciWatchCount = ciCount,
            notificationsEnabled = enabled,
            hasWatchedWork = container.agentNotifier.hasWatchedServers() || ciCount > 0,
            isChecking = checking,
        ),
        onCheckNow = {
            checking = true
            scope.launch {
                try {
                    container.agentNotifier.check(CheckTrigger.MANUAL)
                } finally {
                    checking = false
                }
            }
        },
        onDismiss = onDismiss,
    )
}
