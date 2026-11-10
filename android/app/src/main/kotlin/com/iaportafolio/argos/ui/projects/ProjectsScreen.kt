package com.iaportafolio.argos.ui.projects

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitRepoSummary
import com.iaportafolio.argos.ui.git.GitSummaryBadge
import com.iaportafolio.argos.core.projects.ProjectEntry
import com.iaportafolio.argos.core.projects.ProjectStatusFilter
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.sessions.ConnectStep
import com.iaportafolio.argos.ui.sessions.SessionDialogActions
import com.iaportafolio.argos.ui.sessions.SessionDialogs
import com.iaportafolio.argos.ui.sessions.SessionsLoad

/**
 * Proyectos y sesiones sueltas de un servidor (equivale a `ProjectsView` de iOS + la gestión
 * de proyectos del Mac). [onBack] `null` = panel de detalle en tablet. [folderPicker] pinta el
 * selector visual de carpetas sobre el formulario.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectsScreen(
    state: ProjectsUiState,
    actions: ProjectsActions,
    sessionActions: SessionDialogActions,
    onBack: (() -> Unit)?,
    onOpenPorts: () -> Unit,
    folderPicker: @Composable (startPath: String, onPick: (String) -> Unit, onDismiss: () -> Unit) -> Unit,
    modifier: Modifier = Modifier,
) {
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, actions::messageShown)

    Scaffold(
        modifier = modifier,
        topBar = { ProjectsTopBar(state, actions, onBack, onOpenPorts) },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) { ProjectsContent(state, actions) }
    }

    SessionDialogs(state.sessionDialog, sessionActions)
    ProjectDialogs(state.dialog, actions, folderPicker)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProjectsTopBar(state: ProjectsUiState, actions: ProjectsActions, onBack: (() -> Unit)?, onOpenPorts: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    val ready = state.load == SessionsLoad.Loaded && !state.isBusy
    TopAppBar(
        title = { Text(state.serverName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                }
            }
        },
        actions = {
            IconButton(onClick = actions::refresh, enabled = !state.isBusy) {
                Icon(Icons.Filled.Refresh, contentDescription = stringResource(R.string.sessions_refresh))
            }
            IconButton(onClick = actions::openNewProject, enabled = ready) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.projects_new))
            }
            Box {
                IconButton(onClick = { menuOpen = true }, enabled = ready) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.projects_more))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.sessions_new)) },
                        leadingIcon = { Icon(painterResource(R.drawable.ic_terminal), contentDescription = null) },
                        onClick = { menuOpen = false; actions.openCreateSession() },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.projects_import)) },
                        leadingIcon = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null) },
                        enabled = state.listing.looseSessions.isNotEmpty(),
                        onClick = { menuOpen = false; actions.openImport() },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.ports_menu)) },
                        leadingIcon = { Icon(painterResource(R.drawable.ic_server), contentDescription = null) },
                        onClick = { menuOpen = false; onOpenPorts() },
                    )
                }
            }
        },
    )
}

@Composable
private fun ProjectsContent(state: ProjectsUiState, actions: ProjectsActions) {
    when (val load = state.load) {
        is SessionsLoad.Connecting -> ProgressMessage(
            when (load.step) {
                ConnectStep.VERIFYING -> stringResource(R.string.sessions_connecting, state.serverName)
                ConnectStep.INSTALLING -> stringResource(R.string.sessions_installing)
                ConnectStep.CONFIGURING -> stringResource(R.string.sessions_configuring)
                ConnectStep.LOADING -> stringResource(R.string.projects_loading)
            },
        )
        SessionsLoad.TmuxMissing -> StatusMessage(
            icon = painterResource(R.drawable.ic_terminal),
            title = stringResource(R.string.sessions_tmux_missing_title),
            body = stringResource(R.string.sessions_tmux_missing),
        ) { RetryButton(actions::load) }
        is SessionsLoad.HostKeyChanged -> StatusMessage(
            icon = painterResource(R.drawable.ic_key),
            title = stringResource(R.string.sessions_host_key_title),
            body = load.message,
        ) {
            Button(
                onClick = actions::forgetHostKeyAndRetry,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
            ) { Text(stringResource(R.string.sessions_host_key_trust)) }
        }
        is SessionsLoad.Failed -> StatusMessage(
            icon = rememberVectorPainter(Icons.Filled.Warning),
            title = stringResource(R.string.sessions_failed_title),
            body = load.message,
        ) { RetryButton(actions::load) }
        SessionsLoad.ServerMissing -> StatusMessage(
            icon = painterResource(R.drawable.ic_server),
            title = stringResource(R.string.sessions_server_missing),
        )
        SessionsLoad.Loaded -> PullToRefreshBox(
            isRefreshing = state.isRefreshing,
            onRefresh = actions::refresh,
            modifier = Modifier.fillMaxSize(),
        ) { ProjectList(state, actions) }
    }
}

@Composable
private fun RetryButton(onClick: () -> Unit) {
    Button(onClick = onClick) { Text(stringResource(R.string.action_retry)) }
}

@Composable
private fun ProjectList(state: ProjectsUiState, actions: ProjectsActions) {
    // Siempre desplazable: así el pull-to-refresh funciona también vacía.
    LazyColumn(Modifier.fillMaxSize()) {
        item(key = "filters") { FilterChips(state, actions::setFilter) }
        state.projectsError?.let { error -> item(key = "projects-error") { ProjectsErrorRow(error) } }
        if (state.isEmpty) {
            item(key = "empty") {
                StatusMessage(
                    icon = painterResource(R.drawable.ic_folder),
                    title = stringResource(R.string.projects_empty_title),
                    body = stringResource(R.string.projects_empty),
                    modifier = Modifier.fillParentMaxSize(),
                ) { Button(onClick = actions::openNewProject) { Text(stringResource(R.string.projects_new)) } }
            }
        } else if (state.sections.isEmpty() && state.looseSessions.isEmpty()) {
            item(key = "filtered-empty") {
                StatusMessage(
                    icon = painterResource(R.drawable.ic_folder),
                    title = stringResource(R.string.projects_filter_empty, state.filter.title),
                    body = state.filter.help,
                    modifier = Modifier.fillParentMaxSize(),
                )
            }
        }
        state.sections.forEach { section -> projectSection(section, state, actions) }
        if (state.looseSessions.isNotEmpty()) {
            stickyHeader(key = "loose-header") { SectionHeader(stringResource(R.string.projects_loose_sessions)) }
            items(state.looseSessions, key = { "session:${it.name}" }) { session -> LooseSessionRow(session, actions) }
        }
    }
}

private fun LazyListScope.projectSection(section: ProjectSection, state: ProjectsUiState, actions: ProjectsActions) {
    stickyHeader(key = "group:${section.name}") {
        CollapsibleHeader(section, onToggle = { actions.toggleGroup(section.name) })
    }
    if (!section.isCollapsed) {
        items(section.entries, key = { "project:${it.id}" }) { entry ->
            ProjectRow(entry, isBusy = state.busyProjectId == entry.id, git = state.gitSummaries[entry.project.path], actions = actions)
        }
    }
}

@Composable
private fun FilterChips(state: ProjectsUiState, onSelect: (ProjectStatusFilter) -> Unit) {
    LazyRow(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
    ) {
        items(ProjectStatusFilter.entries, key = { it.id }) { option ->
            val count = state.filterCounts[option] ?: 0
            val label = stringResource(R.string.projects_filter_label, option.title, count)
            FilterChip(
                selected = state.filter == option,
                onClick = { onSelect(option) },
                label = { Text(label) },
                modifier = Modifier.semantics { contentDescription = "$label. ${option.help}" },
            )
        }
    }
}

@Composable
private fun ProjectsErrorRow(message: String) {
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.errorContainer).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer)
        Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onErrorContainer)
    }
}

@Composable
private fun SectionHeader(name: String) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
        Text(
            name,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp).semantics { heading() },
        )
    }
}

@Composable
private fun CollapsibleHeader(section: ProjectSection, onToggle: () -> Unit) {
    val stateText = stringResource(if (section.isCollapsed) R.string.projects_group_collapsed else R.string.projects_group_expanded)
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .clickable(role = Role.Button, onClick = onToggle)
                .padding(horizontal = 16.dp, vertical = 6.dp)
                .semantics(mergeDescendants = true) {
                    heading()
                    stateDescription = stateText
                },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "${section.name} · ${section.entries.size}",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.weight(1f),
            )
            Icon(
                if (section.isCollapsed) Icons.Filled.KeyboardArrowDown else Icons.Filled.KeyboardArrowUp,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

private val RUNNING_GREEN = Color(0xFF30B94D)

@Composable
private fun ProjectRow(entry: ProjectEntry, isBusy: Boolean, git: GitRepoSummary?, actions: ProjectsActions) {
    var menuOpen by remember { mutableStateOf(false) }
    val project = entry.project
    val session = entry.session
    val subtitle = if (session == null) {
        stringResource(R.string.projects_stopped_subtitle, project.path)
    } else {
        "${pluralStringResource(R.plurals.sessions_windows, session.windowCount, session.windowCount)} · ${project.path}"
    }
    val running = stringResource(R.string.projects_running)
    ListItem(
        modifier = Modifier.clickable(role = Role.Button, enabled = !isBusy) { actions.openProject(entry) },
        leadingContent = {
            Icon(
                painterResource(if (entry.isRunning) R.drawable.ic_folder else R.drawable.ic_folder_open),
                contentDescription = null,
                tint = if (entry.isRunning) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        headlineContent = { Text(project.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            val onMac = project.macCheckout?.let { stringResource(R.string.projects_on_mac, it.macName) }
            Text(listOfNotNull(onMac, subtitle).joinToString(" · "), maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                GitSummaryBadge(git, Modifier.padding(end = 8.dp))
                when {
                    isBusy -> CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    entry.isRunning -> Box(
                        Modifier.size(8.dp).background(RUNNING_GREEN, CircleShape).semantics { contentDescription = running },
                    )
                }
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.projects_more_for, project.name))
                    }
                    ProjectMenu(entry, expanded = menuOpen, onDismiss = { menuOpen = false }, actions = actions)
                }
            }
        },
    )
    HorizontalDivider()
}

@Composable
private fun ProjectMenu(entry: ProjectEntry, expanded: Boolean, onDismiss: () -> Unit, actions: ProjectsActions) {
    val project = entry.project
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text(stringResource(if (entry.isRunning) R.string.projects_open else R.string.projects_start)) },
            leadingIcon = { Icon(Icons.Filled.PlayArrow, contentDescription = null) },
            onClick = { onDismiss(); actions.openProject(entry) },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.action_edit)) },
            leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
            onClick = { onDismiss(); actions.openEditProject(project) },
        )
        if (entry.isRunning) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.projects_stop)) },
                leadingIcon = { Icon(painterResource(R.drawable.ic_stop), contentDescription = null) },
                onClick = { onDismiss(); actions.requestStop(project) },
            )
        }
        DropdownMenuItem(
            text = { Text(stringResource(R.string.projects_remove), color = MaterialTheme.colorScheme.error) },
            leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
            onClick = { onDismiss(); actions.requestRemove(project) },
        )
    }
}

@Composable
private fun LooseSessionRow(session: TmuxSession, actions: ProjectsActions) {
    var menuOpen by remember { mutableStateOf(false) }
    val windows = pluralStringResource(R.plurals.sessions_windows, session.windowCount, session.windowCount)
    val subtitle = if (session.isAttached) "$windows · ${stringResource(R.string.sessions_attached)}" else windows
    ListItem(
        modifier = Modifier.clickable(role = Role.Button) { actions.openSession(session) },
        leadingContent = {
            Icon(
                painterResource(R.drawable.ic_terminal),
                contentDescription = null,
                tint = if (session.isAttached) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        headlineContent = { Text(session.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(subtitle) },
        trailingContent = {
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.sessions_more_for, session.name))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.projects_convert)) },
                        leadingIcon = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null) },
                        onClick = { menuOpen = false; actions.openConvert(session) },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.sessions_rename)) },
                        leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                        onClick = { menuOpen = false; actions.openRenameSession(session) },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.sessions_kill), color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Filled.Close, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menuOpen = false; actions.requestKillSession(session) },
                    )
                }
            }
        },
    )
}
