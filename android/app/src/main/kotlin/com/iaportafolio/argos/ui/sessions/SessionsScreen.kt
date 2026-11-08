package com.iaportafolio.argos.ui.sessions

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.tmux.SessionGroup
import com.iaportafolio.argos.core.tmux.SessionGrouping
import com.iaportafolio.argos.core.tmux.TmuxSession
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage

/** Acciones de la pantalla de sesiones. */
interface SessionsActions {
    fun load()
    fun refresh()
    fun forgetHostKeyAndRetry()
    fun openCreate()
    fun openRename(session: TmuxSession)
    fun requestKill(session: TmuxSession)
    fun dismissDialog()
    fun onDialogTextChange(text: String)
    fun submitDialog()
    fun confirmKill()
    fun messageShown()
}

/**
 * Sesiones tmux de un servidor (equivale a la parte de sesiones de `ProjectsView`).
 * [onBack] `null` = panel de detalle en tablet (sin botón atrás). [onOpenSession] abre el
 * terminal en vivo de la sesión tocada.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionsScreen(
    state: SessionsUiState,
    actions: SessionsActions,
    onBack: (() -> Unit)?,
    onOpenSession: (TmuxSession) -> Unit,
    modifier: Modifier = Modifier,
) {
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, actions::messageShown)

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(state.serverName) },
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
                    IconButton(onClick = actions::openCreate, enabled = state.load == SessionsLoad.Loaded && !state.isBusy) {
                        Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.sessions_new))
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            SessionsContent(state, actions, onOpenSession)
        }
    }

    SessionDialogs(state.dialog, actions)
}

@Composable
private fun SessionsContent(state: SessionsUiState, actions: SessionsActions, onOpenSession: (TmuxSession) -> Unit) {
    when (val load = state.load) {
        is SessionsLoad.Connecting -> ProgressMessage(
            when (load.step) {
                ConnectStep.VERIFYING -> stringResource(R.string.sessions_connecting, state.serverName)
                ConnectStep.INSTALLING -> stringResource(R.string.sessions_installing)
                ConnectStep.CONFIGURING -> stringResource(R.string.sessions_configuring)
                ConnectStep.LOADING -> stringResource(R.string.sessions_loading)
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
        ) {
            SessionList(state.groups, actions, onOpenSession)
        }
    }
}

@Composable
private fun RetryButton(onClick: () -> Unit) {
    Button(onClick = onClick) { Text(stringResource(R.string.action_retry)) }
}

@Composable
private fun SessionList(groups: List<SessionGroup>, actions: SessionsActions, onOpenSession: (TmuxSession) -> Unit) {
    // Siempre una lista desplazable: así el pull-to-refresh funciona también vacía.
    LazyColumn(modifier = Modifier.fillMaxSize()) {
        if (groups.isEmpty()) {
            item {
                StatusMessage(
                    icon = painterResource(R.drawable.ic_terminal),
                    title = stringResource(R.string.sessions_empty_title),
                    body = stringResource(R.string.sessions_empty),
                    modifier = Modifier.fillParentMaxSize(),
                )
            }
        }
        groups.forEach { group ->
            stickyHeader(key = "group:${group.id}") { GroupHeader(group.name) }
            items(group.sessions, key = { "session:${it.id}" }) { session ->
                SessionRow(session, actions, onOpenSession)
            }
        }
    }
}

@Composable
private fun GroupHeader(name: String) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
        Text(
            name,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .semantics { heading() },
        )
    }
}

@Composable
private fun SessionRow(session: TmuxSession, actions: SessionsActions, onOpen: (TmuxSession) -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    val windows = pluralStringResource(R.plurals.sessions_windows, session.windowCount, session.windowCount)
    val subtitle = if (session.isAttached) "$windows · ${stringResource(R.string.sessions_attached)}" else windows
    ListItem(
        modifier = Modifier.clickable(role = Role.Button) { onOpen(session) },
        leadingContent = {
            Icon(
                painterResource(R.drawable.ic_terminal),
                contentDescription = null,
                tint = if (session.isAttached) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        headlineContent = { Text(SessionGrouping.shortName(session.name)) },
        supportingContent = { Text(subtitle) },
        trailingContent = {
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.sessions_more_for, session.name))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.sessions_rename)) },
                        leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                        onClick = { menuOpen = false; actions.openRename(session) },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.sessions_kill), color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Filled.Close, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menuOpen = false; actions.requestKill(session) },
                    )
                }
            }
        },
    )
}
