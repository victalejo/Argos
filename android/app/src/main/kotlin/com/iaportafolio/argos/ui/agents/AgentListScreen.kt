package com.iaportafolio.argos.ui.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** Agentes de un proyecto (equivale a `AgentsView` de iOS). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentListScreen(
    viewModel: AgentListViewModel,
    selectedAgentId: String?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, viewModel::messageShown)

    Scaffold(
        modifier = modifier,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = { AgentListTopBar(state, viewModel, onBack) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (val load = state.load) {
                AgentListLoad.Loading -> ProgressMessage(stringResource(R.string.agents_loading))
                is AgentListLoad.Failed -> StatusMessage(
                    icon = rememberVectorPainter(Icons.Filled.Warning),
                    title = stringResource(R.string.agents_failed_title),
                    body = load.message.asString(),
                ) { Button(onClick = viewModel::refresh) { Text(stringResource(R.string.action_retry)) } }
                AgentListLoad.Loaded -> PullToRefreshBox(
                    isRefreshing = state.isRefreshing,
                    onRefresh = viewModel::refresh,
                    modifier = Modifier.fillMaxSize(),
                ) { AgentList(state, selectedAgentId, viewModel) }
            }
        }
    }
    AgentListDialogs(state, viewModel)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AgentListTopBar(state: AgentListUiState, viewModel: AgentListViewModel, onBack: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    TopAppBar(
        title = {
            Column {
                Text(stringResource(R.string.agents_title), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    state.workingDirectory,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
            }
        },
        actions = {
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.agents_chat_options))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    // El gesto de tirar no llega a todos: la recarga también está en el menú.
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.agents_refresh)) },
                        onClick = {
                            menuOpen = false
                            viewModel.refresh()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.agents_login_menu)) },
                        enabled = state.claude != ClaudeAvailability.Missing,
                        onClick = {
                            menuOpen = false
                            viewModel.startLogin()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.agents_token_menu)) },
                        onClick = {
                            menuOpen = false
                            viewModel.showTokenDialog()
                        },
                    )
                }
            }
        },
    )
}

@Composable
private fun AgentList(state: AgentListUiState, selectedAgentId: String?, viewModel: AgentListViewModel) {
    // Siempre desplazable: así el pull-to-refresh funciona también vacía.
    LazyColumn(Modifier.fillMaxSize()) {
        if (state.claude == ClaudeAvailability.Missing) {
            item(key = "missing") {
                if (state.agents.isEmpty()) {
                    StatusMessage(
                        icon = painterResource(R.drawable.ic_sparkles),
                        title = stringResource(R.string.agents_claude_missing_title),
                        body = stringResource(R.string.agents_claude_missing, state.serverName),
                        modifier = Modifier.fillParentMaxSize(),
                    ) { Button(onClick = viewModel::refresh) { Text(stringResource(R.string.agents_claude_recheck)) } }
                } else {
                    ClaudeMissingBanner(state.serverName, viewModel::refresh)
                }
            }
        }
        if (state.claude != ClaudeAvailability.Missing) {
            item(key = "permissions") { PermissionsRow(state.permissions.effective, viewModel::showPermissionsDialog) }
            item(key = "new") { NewAgentHeader(state, viewModel::createAgent) }
        }
        items(state.agents, key = { it.id }) { agent ->
            AgentRowItem(
                agent = agent,
                selected = agent.id == selectedAgentId,
                onOpen = { viewModel.openAgent(agent.id) },
                onStop = { viewModel.stop(agent.id) },
                onResume = { viewModel.resume(agent.id) },
                onDelete = { viewModel.requestDelete(agent.id) },
            )
        }
        if (state.agents.isEmpty() && state.claude != ClaudeAvailability.Missing) {
            item(key = "empty") {
                Text(
                    stringResource(R.string.agents_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
    }
}

/** Fila «Permisos»: el modo con el que arrancarán los agentes nuevos y qué significa. */
@Composable
private fun PermissionsRow(mode: ClaudeAgentCommand.PermissionMode, onClick: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(role = Role.Button, onClick = onClick),
        overlineContent = { Text(stringResource(R.string.agents_permissions_label)) },
        headlineContent = { Text(stringResource(mode.titleRes)) },
        supportingContent = { Text(stringResource(mode.detailRes)) },
    )
}

@Composable
private fun ClaudeMissingBanner(serverName: String, onRecheck: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(16.dp).background(MaterialTheme.colorScheme.errorContainer, RoundedCornerShape(12.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            stringResource(R.string.agents_claude_missing_title),
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onErrorContainer,
        )
        Text(
            stringResource(R.string.agents_claude_missing, serverName),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onErrorContainer,
        )
        OutlinedButton(onClick = onRecheck) { Text(stringResource(R.string.agents_claude_recheck)) }
    }
}

@Composable
private fun NewAgentHeader(state: AgentListUiState, onCreate: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = onCreate, enabled = !state.isCreating, modifier = Modifier.fillMaxWidth()) {
            if (state.isCreating) {
                CircularProgressIndicator(Modifier.padding(end = 8.dp).size(18.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.padding(end = 8.dp))
            }
            Text(stringResource(R.string.agents_new))
        }
        val claudeLine = when (val claude = state.claude) {
            is ClaudeAvailability.SignedIn -> claude.subscription?.takeIf { it.isNotEmpty() }
                ?.let { stringResource(R.string.agents_signed_in_plan, it) }
                ?: stringResource(R.string.agents_signed_in)
            ClaudeAvailability.SignedOut -> stringResource(
                if (state.hasSavedToken) R.string.agents_signed_out_with_token else R.string.agents_signed_out,
            )
            ClaudeAvailability.Missing, ClaudeAvailability.Unknown -> null
        }
        claudeLine?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary) }
        Text(
            stringResource(R.string.agents_new_footer),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private val DATE_FORMAT: DateTimeFormatter = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)

@Composable
private fun AgentRowItem(
    agent: AgentRow,
    selected: Boolean,
    onOpen: () -> Unit,
    onStop: () -> Unit,
    onResume: () -> Unit,
    onDelete: () -> Unit,
) {
    val date = remember(agent.createdAt) { DATE_FORMAT.format(agent.createdAt.atZone(ZoneId.systemDefault())) }
    val statusText = stringResource(if (agent.isAlive) R.string.agents_alive else R.string.agents_dead)
    val modeText = stringResource(agent.permissionMode.titleRes)
    val description = stringResource(R.string.agents_row_description, agent.title, statusText, date, modeText)
    val tint = if (agent.isAlive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    ListItem(
        modifier = Modifier
            .clickable(role = Role.Button, onClick = onOpen)
            .semantics {
                this.selected = selected
                contentDescription = description
            },
        colors = if (selected) {
            ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
        } else {
            ListItemDefaults.colors()
        },
        leadingContent = { Icon(painterResource(R.drawable.ic_sparkles), contentDescription = null, tint = tint) },
        overlineContent = { Text(statusText, color = tint) },
        headlineContent = { Text(agent.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text("$date · $modeText") },
        trailingContent = {
            if (agent.isBusy) {
                CircularProgressIndicator(Modifier.size(24.dp).clearAndSetSemantics { }, strokeWidth = 2.dp)
            } else {
                AgentRowMenu(agent, onOpen, onStop, onResume, onDelete)
            }
        },
    )
}

@Composable
private fun AgentRowMenu(agent: AgentRow, onOpen: () -> Unit, onStop: () -> Unit, onResume: () -> Unit, onDelete: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box(contentAlignment = Alignment.Center) {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.agents_more_for, agent.title))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text(stringResource(R.string.agents_open)) }, onClick = { open = false; onOpen() })
            if (agent.isAlive) {
                DropdownMenuItem(text = { Text(stringResource(R.string.agents_stop)) }, onClick = { open = false; onStop() })
            } else {
                DropdownMenuItem(text = { Text(stringResource(R.string.agents_resume)) }, onClick = { open = false; onResume() })
            }
            DropdownMenuItem(text = { Text(stringResource(R.string.action_delete)) }, onClick = { open = false; onDelete() })
        }
    }
}

@Composable
private fun AgentListDialogs(state: AgentListUiState, viewModel: AgentListViewModel) {
    when (val dialog = state.dialog) {
        null -> Unit
        AgentListDialog.AuthRequired -> AuthRequiredDialog(
            serverName = state.serverName,
            onLogin = viewModel::startLogin,
            onToken = viewModel::showTokenDialog,
            onDismiss = viewModel::dismissDialog,
        )
        AgentListDialog.Token -> TokenDialog(
            hasSavedToken = state.hasSavedToken,
            error = state.tokenError?.asString(),
            onSave = viewModel::saveToken,
            onDelete = viewModel::deleteToken,
            onDismiss = viewModel::dismissDialog,
        )
        AgentListDialog.Permissions -> ProjectPermissionDialog(
            selection = state.permissions,
            onSelect = viewModel::setPermissionChoice,
            onDismiss = viewModel::dismissDialog,
        )
        is AgentListDialog.ConfirmDelete -> AlertDialog(
            onDismissRequest = viewModel::dismissDialog,
            title = { Text(stringResource(R.string.agents_delete_title, dialog.title)) },
            text = { Text(stringResource(R.string.agents_delete_message)) },
            confirmButton = { TextButton(onClick = viewModel::confirmDelete) { Text(stringResource(R.string.action_delete)) } },
            dismissButton = { TextButton(onClick = viewModel::dismissDialog) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}
