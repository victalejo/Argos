package com.iaportafolio.argos.ui.agents

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.PersistentAgentHibernation
import com.iaportafolio.argos.core.agent.ServerAgentInventory
import com.iaportafolio.argos.core.agent.ServerAgentProcess
import com.iaportafolio.argos.core.monitor.ResourceFormat
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString

/** «Agentes en este servidor» (equivale a `ServerAgentsView` de iOS). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerAgentsScreen(viewModel: ServerAgentsViewModel, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.server_agents_title, state.serverName), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (val load = state.load) {
                ServerAgentsLoad.Loading -> ProgressMessage(stringResource(R.string.agents_loading))
                is ServerAgentsLoad.Failed -> StatusMessage(
                    icon = rememberVectorPainter(Icons.Filled.Warning),
                    title = stringResource(R.string.agents_failed_title),
                    body = load.message.asString(),
                ) { Button(onClick = viewModel::refresh) { Text(stringResource(R.string.action_retry)) } }
                is ServerAgentsLoad.Loaded -> PullToRefreshBox(
                    isRefreshing = state.isRefreshing,
                    onRefresh = viewModel::refresh,
                    modifier = Modifier.fillMaxSize(),
                ) { InventoryList(state, load.inventory, viewModel) }
            }
            if (state.isWorking) LinearProgressIndicator(Modifier.padding(horizontal = 16.dp))
        }
    }
    ServerAgentsDialogs(state, viewModel)
}

@Composable
private fun InventoryList(state: ServerAgentsUiState, inventory: ServerAgentInventory, viewModel: ServerAgentsViewModel) {
    val live = inventory.liveAgents
    val stopped = inventory.agents.filter { !it.isAlive }
    LazyColumn(Modifier.fillMaxSize()) {
        item(key = "summary") { Summary(inventory) }
        item(key = "actions") { Actions(state, live.isNotEmpty(), viewModel) }
        item(key = "live-header") { SectionHeader(stringResource(R.string.server_agents_live)) }
        if (live.isEmpty()) {
            item(key = "none") {
                Text(
                    stringResource(R.string.server_agents_none),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
        items(live, key = { "live:${it.sessionID}" }) { agent ->
            AgentProcessRow(agent) {
                TextButton(onClick = { viewModel.stop(agent) }, enabled = !state.isWorking) {
                    Text(stringResource(R.string.server_agents_stop))
                }
            }
        }
        if (stopped.isNotEmpty()) {
            item(key = "stopped-header") { SectionHeader(stringResource(R.string.server_agents_stopped)) }
            items(stopped, key = { "stopped:${it.sessionID}" }) { AgentProcessRow(it, trailing = null) }
        }
    }
}

@Composable
private fun Summary(inventory: ServerAgentInventory) {
    ListItem(
        headlineContent = { Text(stringResource(R.string.server_agents_live_count, inventory.liveAgents.size)) },
        supportingContent = {
            val used = stringResource(R.string.server_agents_memory_used, ResourceFormat.kilobytes(inventory.liveResidentKB))
            val free = inventory.freeMemoryKB?.let { stringResource(R.string.server_agents_memory_free, ResourceFormat.kilobytes(it)) }
            Text(listOfNotNull(used, free).joinToString(" · "))
        },
    )
    HorizontalDivider()
}

@Composable
private fun Actions(state: ServerAgentsUiState, hasLive: Boolean, viewModel: ServerAgentsViewModel) {
    val hibernation = state.hibernation
    val footer = if (hibernation.isEnabled) {
        stringResource(
            R.string.server_agents_hibernate_footer,
            PersistentAgentHibernation.title(hibernation.idleHours),
            PersistentAgentHibernation.BACKGROUND_WORK_WARNING,
        )
    } else {
        stringResource(R.string.server_agents_hibernate_disabled)
    }
    ListItem(
        headlineContent = {
            OutlinedButton(onClick = viewModel::hibernateIdle, enabled = state.candidates.isNotEmpty() && !state.isWorking) {
                Text(stringResource(R.string.server_agents_hibernate, state.candidates.size))
            }
        },
        supportingContent = { Text(footer) },
        trailingContent = {
            TextButton(onClick = viewModel::requestStopAll, enabled = hasLive && !state.isWorking) {
                Text(stringResource(R.string.server_agents_stop_all), color = MaterialTheme.colorScheme.error)
            }
        },
    )
    HorizontalDivider()
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun AgentProcessRow(agent: ServerAgentProcess, trailing: (@Composable () -> Unit)?) {
    val title = when (agent.kind) {
        is ServerAgentProcess.Kind.Persistent -> agent.title
        is ServerAgentProcess.Kind.Panel -> stringResource(R.string.server_agents_mac_conversation)
    }
    val tint = if (agent.isAlive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    ListItem(
        leadingContent = { Icon(painterResource(R.drawable.ic_sparkles), contentDescription = null, tint = tint) },
        headlineContent = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = { Text(agentDetail(agent), maxLines = 2, overflow = TextOverflow.Ellipsis) },
        overlineContent = if (agent.isAlive) {
            { Text(ResourceFormat.kilobytes(agent.residentKB)) }
        } else {
            null
        },
        trailingContent = trailing,
    )
}

@Composable
private fun agentDetail(agent: ServerAgentProcess): String {
    val parts = mutableListOf<String>()
    val meta = (agent.kind as? ServerAgentProcess.Kind.Persistent)?.meta
    meta?.let { parts += ServerAgentsFormat.shortPath(it.workingDirectory) }
    if (agent.hasPendingPermission) parts += stringResource(R.string.server_agents_waiting_permission)
    val idle = agent.idleSeconds
    if (idle != null && agent.isAlive) parts += stringResource(R.string.server_agents_idle, ServerAgentsFormat.idle(idle))
    if (meta != null && !agent.isAlive) {
        parts += stringResource(if (meta.isHibernated) R.string.agents_hibernated else R.string.agents_dead).lowercase()
    }
    return parts.joinToString(" · ")
}

@Composable
private fun ServerAgentsDialogs(state: ServerAgentsUiState, viewModel: ServerAgentsViewModel) {
    if (state.confirmStopAll) {
        AlertDialog(
            onDismissRequest = viewModel::cancelStopAll,
            title = { Text(stringResource(R.string.server_agents_stop_all_title)) },
            text = { Text(stringResource(R.string.server_agents_stop_all_message)) },
            confirmButton = {
                TextButton(onClick = viewModel::confirmStopAll) {
                    Text(stringResource(R.string.server_agents_stop_all), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = viewModel::cancelStopAll) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
    state.actionError?.let { error ->
        AlertDialog(
            onDismissRequest = viewModel::actionErrorShown,
            title = { Text(stringResource(R.string.server_agents_action_failed)) },
            text = { Text(error.asString()) },
            confirmButton = { TextButton(onClick = viewModel::actionErrorShown) { Text(stringResource(R.string.action_ok)) } },
        )
    }
}

/** Formatos de la pantalla (lógica pura, con tests). */
internal object ServerAgentsFormat {
    private const val MINUTE = 60L
    private const val HOUR = 3_600L
    private const val DAY = 86_400L

    /** Ruta corta para mostrar (solo las dos últimas carpetas), como `ProjectRowPath.short`. */
    fun shortPath(path: String): String {
        val components = path.split("/").filter { it.isNotEmpty() }
        return if (components.size > 2) "…/" + components.takeLast(2).joinToString("/") else path
    }

    /** Inactividad en forma breve con dos unidades como mucho: `2 d 3 h`, `5 h 10 min`, `7 min`. */
    fun idle(seconds: Long): String {
        val days = seconds / DAY
        val hours = (seconds % DAY) / HOUR
        val minutes = (seconds % HOUR) / MINUTE
        return when {
            days > 0 -> if (hours > 0) "$days d $hours h" else "$days d"
            hours > 0 -> if (minutes > 0) "$hours h $minutes min" else "$hours h"
            else -> "$minutes min"
        }
    }
}
