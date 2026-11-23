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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.core.tmux.CodingAgent
import com.iaportafolio.argos.ui.claude.ClaudeActivityBadge
import com.iaportafolio.argos.ui.claude.CodingAgentIcon
import com.iaportafolio.argos.core.tmux.TmuxWindow
import com.iaportafolio.argos.core.tmux.WindowColor
import com.iaportafolio.argos.core.tmux.WindowTabs
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.asString

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
    onRename: (TmuxWindow) -> Unit = {},
    onColor: (TmuxWindow, WindowColor?) -> Unit = { _, _ -> },
    onRetry: () -> Unit = {},
) {
    val repeated = remember(state.windows, state.claudeWindows) {
        WindowTabs.repeatedAgents(state.windows, claudeReported = state.claudeWindows.keys)
    }
    Row(modifier.fillMaxWidth().background(TerminalColors.Bar), verticalAlignment = Alignment.CenterVertically) {
        if (state.windows.isEmpty()) {
            // Sin listado todavía (cargando o fallido): la barra se ve igual, con el «+»
            // disponible — crear una ventana no necesita la lista.
            WindowBarPlaceholder(state.windowsError, onRetry, Modifier.weight(1f))
        } else {
            Row(
                Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 6.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                state.windows.forEach { window ->
                    WindowTab(
                        window,
                        repeated,
                        claude = state.claudeWindows[window.index],
                        canClose = state.windows.size > 1,
                        onSelect = onSelect,
                        onClose = onClose,
                        onRename = onRename,
                        onColor = onColor,
                    )
                }
            }
        }
        AddMenu(state.installedAgents, onNew, onNewAgent)
    }
}

/** Barra sin ventanas leídas: «cargando» o el error con «Reintentar» (nunca barra ausente). */
@Composable
private fun WindowBarPlaceholder(error: UiText?, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.heightIn(min = 48.dp).padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (error != null) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = TerminalColors.OnBarSecondary, modifier = Modifier.size(16.dp))
            Text(
                error.asString(),
                color = TerminalColors.OnBarSecondary,
                style = MaterialTheme.typography.labelMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onRetry) { Text(stringResource(R.string.action_retry)) }
        } else {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = TerminalColors.OnBar)
            Text(
                stringResource(R.string.terminal_window_loading),
                color = TerminalColors.OnBarSecondary,
                style = MaterialTheme.typography.labelMedium,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowTab(
    window: TmuxWindow,
    repeatedAgents: Set<CodingAgent>,
    claude: ClaudeActivity?,
    canClose: Boolean,
    onSelect: (TmuxWindow) -> Unit,
    onClose: (TmuxWindow) -> Unit,
    onRename: (TmuxWindow) -> Unit,
    onColor: (TmuxWindow, WindowColor?) -> Unit,
) {
    val agent = WindowTabs.agent(window, claudeReported = claude != null)
    val title = WindowTabs.title(window, agent)
    // La insignia de Claude añade su estado al leerse la pestaña (descendiente fusionado).
    val description = stringResource(R.string.terminal_window_description, window.index, title ?: window.name)
    val closeLabel = stringResource(R.string.terminal_window_close)
    // Activa en blanco sobre el acento; inactiva en claro sobre fondo atenuado: antes la
    // inactiva era texto gris SIN fondo sobre la barra y apenas se distinguía.
    val content = if (window.isActive) Color.White else TerminalColors.OnBar
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
                .background(if (window.isActive) TerminalColors.KeyActive else TerminalColors.Key.copy(alpha = 0.45f))
                .combinedClickable(
                    role = Role.Tab,
                    onClick = { onSelect(window) },
                    onLongClick = { menuOpen = true },
                    onLongClickLabel = stringResource(R.string.terminal_window_options),
                )
                .padding(horizontal = 10.dp)
                .semantics(mergeDescendants = true) {
                    selected = window.isActive
                    contentDescription = description
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            // Punto de color de la ventana (como en Mac): a la vista sin abrir el menú.
            window.color?.let { color -> Box(Modifier.size(8.dp).background(color.swatch(), CircleShape)) }
            if (agent != null) {
                CodingAgentIcon(agent, size = 13.dp)
            } else {
                Text(
                    ">_",
                    color = content,
                    fontFamily = TerminalMonoFontFamily,
                    fontWeight = FontWeight.Bold,
                    fontSize = 12.sp,
                    modifier = Modifier.clearAndSetSemantics { },
                )
            }
            // El número distingue las ventanas sin agente y las de un agente repetido.
            if (agent == null || agent in repeatedAgents) {
                Text(window.index.toString(), color = content, fontFamily = TerminalMonoFontFamily, fontSize = 13.sp)
            }
            if (title != null) {
                Text(
                    title,
                    color = content,
                    fontFamily = TerminalMonoFontFamily,
                    fontSize = 13.sp,
                    fontWeight = if (window.isActive) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            claude?.let { ClaudeActivityBadge(it, size = 12.dp) }
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.terminal_window_rename)) },
                leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                onClick = {
                    menuOpen = false
                    onRename(window)
                },
            )
            WindowColorItems(window) { color ->
                menuOpen = false
                onColor(window, color)
            }
            // Cerrar la última ventana mataría la sesión.
            if (canClose) {
                HorizontalDivider()
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
                    leadingIcon = { CodingAgentIcon(agent, size = 18.dp) },
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

/** Colores de la pestaña (los de `WindowColor`, como el Mac) y «Sin color». */
@Composable
private fun WindowColorItems(window: TmuxWindow, onPick: (WindowColor?) -> Unit) {
    HorizontalDivider()
    WindowColor.entries.forEach { color ->
        DropdownMenuItem(
            text = { Text(color.displayName) },
            leadingIcon = { Box(Modifier.size(14.dp).background(color.swatch(), CircleShape)) },
            trailingIcon = if (window.color == color) ({ Icon(Icons.Filled.Check, contentDescription = null) }) else null,
            onClick = { onPick(color) },
        )
    }
    if (window.color != null) {
        DropdownMenuItem(text = { Text(stringResource(R.string.terminal_window_no_color)) }, onClick = { onPick(null) })
    }
}

/** Tono de cada color de pestaña (paleta de sistema de Apple). */
internal fun WindowColor.swatch(): Color = when (this) {
    WindowColor.RED -> Color(0xFFFF453A)
    WindowColor.ORANGE -> Color(0xFFFF9F0A)
    WindowColor.YELLOW -> Color(0xFFFFD60A)
    WindowColor.GREEN -> Color(0xFF30D158)
    WindowColor.MINT -> Color(0xFF66D4CF)
    WindowColor.BLUE -> Color(0xFF0A84FF)
    WindowColor.PURPLE -> Color(0xFFBF5AF2)
    WindowColor.PINK -> Color(0xFFFF375F)
    WindowColor.GRAY -> Color(0xFF98989D)
}

/** «Renombrar ventana» con la validación de tmux en vivo. */
@Composable
fun RenameWindowDialog(rename: WindowRename, onText: (String) -> Unit, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.terminal_window_rename_title, rename.window.index)) },
        text = {
            OutlinedTextField(
                value = rename.text,
                onValueChange = onText,
                singleLine = true,
                isError = rename.error != null,
                supportingText = rename.error?.let { error -> { Text(error) } },
            )
        },
        confirmButton = { TextButton(onClick = onConfirm, enabled = rename.text.isNotBlank() && rename.error == null) { Text(stringResource(R.string.action_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
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
