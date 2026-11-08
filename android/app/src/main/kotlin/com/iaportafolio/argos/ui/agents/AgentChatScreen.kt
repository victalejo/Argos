package com.iaportafolio.argos.ui.agents

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString
import kotlinx.coroutines.launch

/**
 * Conversación con un agente persistente (equivale a `AgentChatView` de iOS). Se engancha al
 * mostrarse y se desengancha en ON_STOP o al salir: el agente sigue en el servidor.
 * Con [onBack] nulo va de panel de detalle, junto a la lista.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentChatScreen(
    viewModel: AgentChatViewModel,
    agentId: String,
    onBack: (() -> Unit)?,
    onClosed: () -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    // Estado local y síncrono, con la composición del IME: nunca pasa por el ViewModel, o se
    // perderían acentos y sugerencias a mitad de palabra.
    var draft by rememberSaveable(agentId, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue("")) }
    var follow by rememberSaveable(agentId) { mutableStateOf(true) }
    val currentOnClosed by rememberUpdatedState(onClosed)

    LifecycleStartEffect(viewModel) {
        viewModel.onStart()
        onStopOrDispose { viewModel.onStop() }
    }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                AgentChatEvent.MessageSent -> {
                    draft = TextFieldValue("")
                    follow = true
                }
                AgentChatEvent.Closed -> currentOnClosed()
            }
        }
    }

    Scaffold(
        contentWindowInsets = WindowInsets(0),
        topBar = { ChatTopBar(state, viewModel, onBack) },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .consumeWindowInsets(padding)
                .windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars)),
        ) {
            when (val load = state.load) {
                AgentChatLoad.Loading -> ProgressMessage(stringResource(R.string.agents_chat_loading))
                is AgentChatLoad.Failed -> StatusMessage(
                    icon = rememberVectorPainter(Icons.Filled.Warning),
                    title = stringResource(R.string.agents_chat_failed_title),
                    body = load.message.asString(),
                ) { Button(onClick = viewModel::reconnect) { Text(stringResource(R.string.action_retry)) } }
                AgentChatLoad.Missing -> StatusMessage(
                    icon = painterResource(R.drawable.ic_sparkles),
                    title = stringResource(R.string.agents_chat_missing_title),
                    body = stringResource(R.string.agents_chat_missing),
                )
                AgentChatLoad.Ready -> ChatContent(
                    state = state,
                    viewModel = viewModel,
                    draft = draft,
                    onDraftChange = { draft = it },
                    follow = follow,
                    onFollowChange = { follow = it },
                )
            }
        }
    }
    state.confirmResumeMode?.let { mode ->
        ConfirmResumeDialog(mode, onConfirm = viewModel::confirmResume, onDismiss = viewModel::cancelResume)
    }
    if (state.confirmDelete) {
        AlertDialog(
            onDismissRequest = viewModel::cancelDelete,
            title = { Text(stringResource(R.string.agents_delete_title, state.title)) },
            text = { Text(stringResource(R.string.agents_delete_message)) },
            confirmButton = { TextButton(onClick = viewModel::confirmDelete) { Text(stringResource(R.string.action_delete)) } },
            dismissButton = { TextButton(onClick = viewModel::cancelDelete) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatTopBar(state: AgentChatUiState, viewModel: AgentChatViewModel, onBack: (() -> Unit)?) {
    var menuOpen by remember { mutableStateOf(false) }
    TopAppBar(
        title = {
            Column {
                Text(state.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                ChatSubtitle(state)
            }
        },
        navigationIcon = {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                }
            }
        },
        actions = {
            if (state.load == AgentChatLoad.Ready) {
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.agents_chat_options))
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        if (state.isAlive) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.agents_stop)) },
                                enabled = !state.isStopping,
                                onClick = {
                                    menuOpen = false
                                    viewModel.stop()
                                },
                            )
                        } else {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.agents_resume)) },
                                enabled = !state.isResuming,
                                onClick = {
                                    menuOpen = false
                                    viewModel.resume()
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.agents_chat_reload)) },
                            onClick = {
                                menuOpen = false
                                viewModel.reconnect()
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.agents_chat_delete)) },
                            enabled = !state.isDeleting,
                            onClick = {
                                menuOpen = false
                                viewModel.requestDelete()
                            },
                        )
                    }
                }
            }
        },
    )
}

/** Estado y modo de permisos; el modo nunca se recorta: dice si el agente corre sin preguntar. */
@Composable
private fun ChatSubtitle(state: AgentChatUiState) {
    val mode = state.permissionMode
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            stringResource(statusText(state.status)),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.weight(1f, fill = false).semantics { liveRegion = LiveRegionMode.Polite },
        )
        if (mode != null) {
            Text(
                " · ${stringResource(mode.titleRes)}",
                maxLines = 1,
                softWrap = false,
                style = MaterialTheme.typography.bodySmall,
                color = if (mode == ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS) MaterialTheme.colorScheme.error else Color.Unspecified,
            )
        }
    }
}

private fun statusText(status: AgentChatStatus): Int = when (status) {
    AgentChatStatus.CONNECTING -> R.string.agents_chat_status_connecting
    AgentChatStatus.WORKING -> R.string.agents_chat_status_working
    AgentChatStatus.IDLE -> R.string.agents_chat_status_idle
    AgentChatStatus.AWAITING_PERMISSION -> R.string.agents_chat_status_permission
    AgentChatStatus.TERMINATED -> R.string.agents_chat_status_terminated
    AgentChatStatus.ERROR -> R.string.agents_chat_status_error
}

@Composable
private fun ChatContent(
    state: AgentChatUiState,
    viewModel: AgentChatViewModel,
    draft: TextFieldValue,
    onDraftChange: (TextFieldValue) -> Unit,
    follow: Boolean,
    onFollowChange: (Boolean) -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        ConnectionBanner(state.connection, viewModel::reconnect)
        if (!state.isAlive) DeadAgentBanner(state.isResuming, viewModel::resume)
        state.error?.let { ErrorBanner(it.asString(), viewModel::errorDismissed) }
        Transcript(state, follow, onFollowChange, Modifier.weight(1f))
        state.visiblePermission?.let { card ->
            AgentPermissionCardView(
                card = card,
                enabled = state.canDecidePermission,
                showOfflineHint = state.connection != AgentConnection.Connected,
                onDecide = { allow -> viewModel.decidePermission(card.requestId, allow) },
            )
        }
        Composer(state, draft, onDraftChange, onSend = { viewModel.send(draft.text) })
    }
}

@Composable
private fun Transcript(state: AgentChatUiState, follow: Boolean, onFollowChange: (Boolean) -> Unit, modifier: Modifier) {
    val listState = rememberLazyListState()
    val scroller = remember(listState) { TranscriptScroller(listState) }
    val scope = rememberCoroutineScope()
    val currentFollowChange by rememberUpdatedState(onFollowChange)
    val showWorking = state.status == AgentChatStatus.WORKING
    val lastIndex = state.rows.size + (if (showWorking) 1 else 0) - 1

    // Solo quien desplaza a mano (dedo, teclado, TalkBack) suelta o recupera el final.
    LaunchedEffect(scroller) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling && !scroller.isProgrammatic && listState.layoutInfo.totalItemsCount > 0) {
                currentFollowChange(listState.isAtBottom())
            }
        }
    }
    // Fila nueva, teclado que encoge la lista o Markdown que crece: se sigue al final,
    // sin pelear con un dedo en la pantalla.
    val viewport by remember(listState) { derivedStateOf { listState.layoutInfo.viewportSize.height } }
    val lastSize by remember(listState) { derivedStateOf { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.size } }
    LaunchedEffect(lastIndex, viewport, lastSize, follow) {
        if (follow && lastIndex >= 0 && !listState.isScrollInProgress) scroller.scrollToEnd(lastIndex)
    }

    Box(modifier.fillMaxWidth()) {
        if (state.rows.isEmpty()) {
            if (state.isReplaying) {
                ProgressMessage(stringResource(R.string.agents_chat_loading))
            } else {
                StatusMessage(
                    icon = painterResource(R.drawable.ic_sparkles),
                    title = stringResource(R.string.agents_chat_empty_title),
                    body = stringResource(R.string.agents_chat_empty, state.workingDirectory),
                )
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(state.rows, key = { it.key }, contentType = { it::class }) { row -> TranscriptRow(row) }
                if (showWorking) item(key = WORKING_KEY) { WorkingRow() }
            }
        }
        if (!follow && state.rows.isNotEmpty()) {
            SmallFloatingActionButton(
                onClick = {
                    onFollowChange(true)
                    scope.launch { scroller.scrollToEnd(lastIndex.coerceAtLeast(0)) }
                },
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp),
            ) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = stringResource(R.string.agents_chat_to_bottom))
            }
        }
    }
}

private const val WORKING_KEY = "working"

/** Más que cualquier fila: la lista lo recorta a su final. No `Int.MAX_VALUE`: se le suma el padding. */
private const val END_OFFSET_PX = 1_000_000

/** Distingue el desplazamiento automático del de la persona, que es el único que cuenta. */
private class TranscriptScroller(private val listState: LazyListState) {
    var isProgrammatic = false
        private set

    suspend fun scrollToEnd(lastIndex: Int) {
        isProgrammatic = true
        try {
            listState.scrollToItem(lastIndex, END_OFFSET_PX)
            // La lista se mide en el siguiente fotograma.
            withFrameNanos { }
        } finally {
            isProgrammatic = false
        }
    }
}

private fun LazyListState.isAtBottom(): Boolean {
    val info = layoutInfo
    val last = info.visibleItemsInfo.lastOrNull()
    return TranscriptFollow.isAtBottom(
        lastVisibleIndex = last?.index,
        totalItems = info.totalItemsCount,
        lastVisibleEnd = last?.let { it.offset + it.size } ?: 0,
        viewportEnd = info.viewportEndOffset - info.afterContentPadding,
    )
}

@Composable
private fun WorkingRow() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
        Text(
            stringResource(R.string.agents_chat_status_working),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ConnectionBanner(connection: AgentConnection, onReconnect: () -> Unit) {
    val text = when (connection) {
        AgentConnection.Connecting, AgentConnection.Connected -> return
        is AgentConnection.Retrying -> connection.retryInSeconds
            ?.let { stringResource(R.string.agents_chat_retrying_in, it) }
            ?: stringResource(R.string.agents_chat_reconnecting, connection.attempt)
        is AgentConnection.Lost -> "${stringResource(R.string.agents_chat_lost_title)} ${connection.message.asString()}"
    }
    Banner(
        text = text,
        container = MaterialTheme.colorScheme.secondaryContainer,
        content = MaterialTheme.colorScheme.onSecondaryContainer,
    ) {
        TextButton(onClick = onReconnect) { Text(stringResource(R.string.agents_chat_reconnect)) }
    }
}

@Composable
private fun DeadAgentBanner(isResuming: Boolean, onResume: () -> Unit) {
    Banner(
        text = stringResource(R.string.agents_chat_dead),
        container = MaterialTheme.colorScheme.tertiaryContainer,
        content = MaterialTheme.colorScheme.onTertiaryContainer,
    ) {
        Button(onClick = onResume, enabled = !isResuming) {
            if (isResuming) CircularProgressIndicator(Modifier.padding(end = 8.dp).size(16.dp), strokeWidth = 2.dp)
            Text(stringResource(R.string.agents_resume))
        }
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    Banner(
        text = message,
        container = MaterialTheme.colorScheme.errorContainer,
        content = MaterialTheme.colorScheme.onErrorContainer,
    ) {
        IconButton(onClick = onDismiss) {
            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.agents_chat_dismiss_error))
        }
    }
}

@Composable
private fun Banner(
    text: String,
    container: Color,
    content: Color,
    action: @Composable () -> Unit,
) {
    Surface(color = container, contentColor = content, modifier = Modifier.fillMaxWidth()) {
        Row(
            Modifier.padding(horizontal = 16.dp, vertical = 8.dp).semantics { liveRegion = LiveRegionMode.Polite },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
            action()
        }
    }
}

@Composable
private fun Composer(state: AgentChatUiState, draft: TextFieldValue, onDraftChange: (TextFieldValue) -> Unit, onSend: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = draft,
            onValueChange = onDraftChange,
            modifier = Modifier.weight(1f),
            enabled = state.isAlive,
            // Mientras se envía no se edita: al confirmarse el envío se vacía la caja.
            readOnly = state.isSending,
            maxLines = 6,
            placeholder = {
                Text(stringResource(if (state.isAlive) R.string.agents_chat_placeholder else R.string.agents_chat_placeholder_dead))
            },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
        )
        FilledIconButton(onClick = onSend, enabled = state.canSend && draft.text.isNotBlank()) {
            if (state.isSending) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = stringResource(R.string.agents_chat_send))
            }
        }
    }
}
