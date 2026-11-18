package com.iaportafolio.argos.ui.terminal

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.tmux.TmuxPaneDirection

/** Paneles de tmux en el menú del terminal (como el menú «Panel» del Mac): dividir, moverse, ampliar y cerrar. */
@Composable
internal fun PaneMenuItems(panes: TerminalWindowsViewModel, close: () -> Unit) {
    HorizontalDivider()
    Text(
        stringResource(R.string.terminal_panes),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
    )
    Item(R.string.terminal_pane_split_side) { panes.splitPane(vertical = false); close() }
    Item(R.string.terminal_pane_split_below) { panes.splitPane(vertical = true); close() }
    TmuxPaneDirection.entries.forEach { direction ->
        Item(direction.labelRes()) { panes.selectPane(direction); close() }
    }
    Item(R.string.terminal_pane_zoom) { panes.zoomPane(); close() }
    Item(R.string.terminal_pane_kill) { panes.killPane(); close() }
}

@Composable
private fun Item(@StringRes label: Int, onClick: () -> Unit) {
    DropdownMenuItem(text = { Text(stringResource(label)) }, onClick = onClick)
}

@StringRes
private fun TmuxPaneDirection.labelRes(): Int = when (this) {
    TmuxPaneDirection.UP -> R.string.terminal_pane_up
    TmuxPaneDirection.DOWN -> R.string.terminal_pane_down
    TmuxPaneDirection.LEFT -> R.string.terminal_pane_left
    TmuxPaneDirection.RIGHT -> R.string.terminal_pane_right
}
