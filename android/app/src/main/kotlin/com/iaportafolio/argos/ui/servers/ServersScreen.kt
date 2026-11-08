package com.iaportafolio.argos.ui.servers

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.StatusMessage

/** Lista de servidores (equivale a `ServerList` de Apple). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServersScreen(
    state: ServersUiState,
    selectedServerId: String?,
    onAdd: () -> Unit,
    onOpen: (Server) -> Unit,
    onEdit: (Server) -> Unit,
    onRequestDelete: (Server) -> Unit,
    onConfirmDelete: () -> Unit,
    onCancelDelete: () -> Unit,
    onForgetHostKey: (Server) -> Unit,
    onMessageShown: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, onMessageShown)

    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text(stringResource(R.string.servers_title)) }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = onAdd,
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text(stringResource(R.string.servers_add)) },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        if (state.servers.isEmpty()) {
            StatusMessage(
                icon = painterResource(R.drawable.ic_server),
                title = stringResource(R.string.servers_empty_title),
                body = stringResource(R.string.servers_empty),
                modifier = Modifier.padding(padding),
            ) {
                Button(onClick = onAdd) { Text(stringResource(R.string.servers_add)) }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(bottom = FAB_CLEARANCE),
            ) {
                items(state.servers, key = { it.id }) { server ->
                    ServerRow(
                        server = server,
                        selected = server.id == selectedServerId,
                        onOpen = { onOpen(server) },
                        onEdit = { onEdit(server) },
                        onDelete = { onRequestDelete(server) },
                        onForgetHostKey = { onForgetHostKey(server) },
                    )
                }
            }
        }
    }

    state.pendingDeletion?.let { server ->
        AlertDialog(
            onDismissRequest = onCancelDelete,
            title = { Text(stringResource(R.string.servers_delete_title, server.name)) },
            text = { Text(stringResource(R.string.servers_delete_message)) },
            confirmButton = {
                TextButton(onClick = onConfirmDelete) {
                    Text(stringResource(R.string.servers_delete_confirm), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = onCancelDelete) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

@Composable
private fun ServerRow(
    server: Server,
    selected: Boolean,
    onOpen: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onForgetHostKey: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    ListItem(
        modifier = Modifier
            .semantics { this.selected = selected }
            .clickable(role = Role.Button, onClick = onOpen),
        colors = if (selected) {
            ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
        } else {
            ListItemDefaults.colors()
        },
        leadingContent = {
            Icon(painterResource(R.drawable.ic_server), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        },
        headlineContent = { Text(server.name) },
        supportingContent = { Text(server.address()) },
        trailingContent = {
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.servers_more_for, server.name))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.action_edit)) },
                        leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                        onClick = { menuOpen = false; onEdit() },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.servers_forget_host_key)) },
                        leadingIcon = { Icon(Icons.Filled.Lock, contentDescription = null) },
                        onClick = { menuOpen = false; onForgetHostKey() },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menuOpen = false; onDelete() },
                    )
                }
            }
        },
    )
}

/** `usuario@host` y el puerto solo si no es el 22 (como `ServerRowView`). */
private fun Server.address(): String =
    "$username@$host" + if (port == Server.DEFAULT_PORT) "" else ":$port"

private val FAB_CLEARANCE = 88.dp
