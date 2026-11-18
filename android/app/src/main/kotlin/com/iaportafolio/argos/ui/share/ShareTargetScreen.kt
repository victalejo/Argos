package com.iaportafolio.argos.ui.share

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage

/** «Compartir» → Argos: servidor y después proyecto o sesión donde subir lo compartido. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareTargetScreen(state: ShareTargetUiState, viewModel: ShareTargetViewModel, onClose: () -> Unit) {
    val server = state.selectedServer
    BackHandler(enabled = server != null, onBack = viewModel::backToServers)
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        server?.name ?: pluralStringResource(R.plurals.share_title, state.attachments.size, state.attachments.size),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = {
                    if (server != null) {
                        IconButton(onClick = viewModel::backToServers) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                        }
                    } else {
                        IconButton(onClick = onClose) { Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_cancel)) }
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (server == null) ServerList(state, viewModel) else DestinationList(state, viewModel)
        }
    }
}

@Composable
private fun ServerList(state: ShareTargetUiState, viewModel: ShareTargetViewModel) {
    if (state.servers.isEmpty()) {
        StatusMessage(icon = painterResource(R.drawable.ic_server), title = stringResource(R.string.share_no_servers))
        return
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item { Hint(stringResource(R.string.share_pick_server, state.attachments.joinToString(", ") { it.displayName ?: "?" })) }
        items(state.servers, key = { it.id }) { server ->
            ListItem(
                modifier = Modifier.clickable(role = Role.Button) { viewModel.selectServer(server) },
                leadingContent = { Icon(painterResource(R.drawable.ic_server), contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                headlineContent = { Text(server.name) },
                supportingContent = { Text("${server.username}@${server.host}") },
            )
            HorizontalDivider()
        }
    }
}

@Composable
private fun DestinationList(state: ShareTargetUiState, viewModel: ShareTargetViewModel) {
    when (val load = state.load) {
        ShareLoad.Idle, ShareLoad.Loading -> ProgressMessage(stringResource(R.string.share_loading))
        is ShareLoad.Failed -> StatusMessage(
            icon = rememberVectorPainter(Icons.Filled.Warning),
            title = stringResource(R.string.sessions_failed_title),
            body = load.message,
        ) { state.selectedServer?.let { server -> Button(onClick = { viewModel.selectServer(server) }) { Text(stringResource(R.string.action_retry)) } } }
        is ShareLoad.Loaded -> if (load.destinations.isEmpty()) {
            StatusMessage(icon = painterResource(R.drawable.ic_folder), title = stringResource(R.string.share_no_projects))
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                item { Hint(stringResource(R.string.share_pick_project)) }
                items(load.destinations, key = { "${it::class.simpleName}:${it.sessionName}" }) { destination ->
                    DestinationRow(destination) { viewModel.choose(destination) }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun DestinationRow(destination: ShareDestination, onClick: () -> Unit) {
    val (icon, title, subtitle) = when (destination) {
        is ShareDestination.ProjectTarget -> Triple(
            if (destination.isRunning) R.drawable.ic_folder else R.drawable.ic_folder_open,
            destination.project.name,
            if (destination.isRunning) destination.project.path else stringResource(R.string.projects_stopped_subtitle, destination.project.path),
        )
        is ShareDestination.SessionTarget -> Triple(R.drawable.ic_terminal, destination.session.name, stringResource(R.string.projects_loose_sessions))
    }
    ListItem(
        modifier = Modifier.clickable(role = Role.Button, onClick = onClick),
        leadingContent = { Icon(painterResource(icon), contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
        headlineContent = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(subtitle, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
    )
}

@Composable
private fun Hint(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
    )
}
