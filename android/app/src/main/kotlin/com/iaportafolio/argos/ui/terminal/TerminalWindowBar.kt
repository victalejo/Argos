package com.iaportafolio.argos.ui.terminal

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.core.tmux.WindowTabs

/**
 * Pestañas de las ventanas tmux (equivale a `TerminalWindowBar` de iOS): `>_ 1` para las
 * ventanas normales y el nombre del agente cuando corre uno. El «+» abre un terminal o lanza un
 * agente; mantener pulsada una pestaña ofrece cerrarla.
 */
@Composable
fun TerminalWindowBar(
    state: TerminalWindowsUiState,
    onSelect: (TmuxWindow) -> Unit,
    onNew: () -> Unit,
    onNewAgent: (CodingAgent) -> Unit,
    onClose: (TmuxWindow) -> Unit,
    modifier: Modifier = Modifier,
) {
    val repeated = remember(state.windows) { WindowTabs.repeatedAgents(state.windows, claudeReported = emptySet()) }
    Row(modifier.fillMaxWidth().background(TerminalColors.Bar), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier
                .weight(1f)
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 6.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            state.windows.forEach { window ->
                WindowTab(window, repeated, canClose = state.windows.size > 1, onSelect = onSelect, onClose = onClose)
            }
        }
        AddMenu(state.installedAgents, onNew, onNewAgent)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowTab(
    window: TmuxWindow,
    repeatedAgents: Set<CodingAgent>,
    canClose: Boolean,
    onSelect: (TmuxWindow) -> Unit,
    onClose: (TmuxWindow) -> Unit,
) {
    val agent = WindowTabs.agent(window, claudeReported = false)
    val title = WindowTabs.title(window, agent)
    val description = stringResource(R.string.terminal_window_description, window.index, title ?: window.name)
    val closeLabel = stringResource(R.string.terminal_window_close)
    val content = if (window.isActive) TerminalColors.OnBar else TerminalColors.OnBarSecondary
    var menuOpen by remember { mutableStateOf(false) }
    // La pestaña activa (recién creada o elegida) se trae a la vista si quedó fuera.
    val bringIntoView = remember { BringIntoViewRequester() }
    LaunchedEffect(window.isActive) { if (window.isActive) bringIntoView.bringIntoView() }
    Box {
        Row(
            Modifier
                .bringIntoViewRequester(bringIntoView)
                .heightIn(min = 48.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(if (window.isActive) TerminalColors.Key else Color.Transparent)
                .combinedClickable(
                    role = Role.Tab,
                    onClick = { onSelect(window) },
                    // Cerrar la última ventana mataría la sesión: sin menú que ofrecer.
                    onLongClick = if (canClose) ({ menuOpen = true }) else null,
                    onLongClickLabel = if (canClose) closeLabel else null,
                )
                .padding(horizontal = 10.dp)
                .semantics(mergeDescendants = true) {
                    selected = window.isActive
                    contentDescription = description
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            if (agent != null) {
                Icon(painterResource(R.drawable.ic_sparkles), contentDescription = null, tint = content, modifier = Modifier.size(14.dp))
            } else {
                Text(
                    ">_",
                    color = if (window.isActive) TerminalColors.KeyActive else content,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    modifier = Modifier.clearAndSetSemantics { },
                )
            }
            // El número distingue las ventanas sin agente y las de un agente repetido.
            if (agent == null || agent in repeatedAgents) {
                Text(window.index.toString(), color = content, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            }
            if (title != null) {
                Text(
                    title,
                    color = content,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = if (window.isActive) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(closeLabel) },
                leadingIcon = { Icon(Icons.Filled.Close, contentDescription = null) },
                onClick = {
                    menuOpen = false
                    onClose(window)
                },
            )
        }
    }
}

@Composable
private fun AddMenu(installedAgents: Set<CodingAgent>?, onNew: () -> Unit, onNewAgent: (CodingAgent) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.terminal_window_new), tint = TerminalColors.OnBar)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.terminal_window_terminal)) },
                leadingIcon = { Icon(painterResource(R.drawable.ic_terminal), contentDescription = null) },
                onClick = {
                    open = false
                    onNew()
                },
            )
            HorizontalDivider()
            CodingAgent.entries.forEach { agent ->
                val installed = installedAgents?.contains(agent) ?: true
                val label = if (installed) {
                    stringResource(R.string.terminal_window_start_agent, agent.displayName)
                } else {
                    stringResource(R.string.terminal_window_agent_missing, agent.displayName)
                }
                DropdownMenuItem(
                    text = { Text(label) },
                    leadingIcon = { Icon(painterResource(R.drawable.ic_sparkles), contentDescription = null) },
                    enabled = installed,
                    onClick = {
                        open = false
                        onNewAgent(agent)
                    },
                )
            }
        }
    }
}

/** Confirmación de cierre de una ventana en la que corre algo. */
@Composable
fun CloseWindowDialog(window: TmuxWindow, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.terminal_window_close_title, window.index)) },
        text = { Text(stringResource(R.string.terminal_window_close_body)) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.terminal_window_close), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}
