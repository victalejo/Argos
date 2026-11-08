package com.iaportafolio.argos.ui.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.TerminalSettings
import com.iaportafolio.argos.terminal.RemoteTerminalSession
import com.iaportafolio.argos.terminal.RemoteTerminalView
import com.iaportafolio.argos.ui.common.asString

/**
 * Terminal en vivo de una sesión tmux (equivale a `TerminalScreen` de iOS, sin las pestañas
 * de ventanas todavía): barra con el nombre de la sesión, el emulador y la fila de teclas
 * extra pegada al teclado.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(viewModel: TerminalViewModel<RemoteTerminalSession>, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    var terminalView by remember { mutableStateOf<RemoteTerminalView?>(null) }

    // Detach al pasar a segundo plano y reattach al volver (la sesión sigue viva en tmux).
    LifecycleStartEffect(viewModel) {
        viewModel.onStart()
        onStopOrDispose { viewModel.onStop() }
    }

    Scaffold(
        containerColor = TerminalColors.Background,
        contentWindowInsets = WindowInsets(0),
        topBar = {
            TerminalTopBar(
                state = state,
                onBack = onBack,
                onToggleKeyboard = { terminalView?.toggleKeyboard() },
                onPaste = { terminalView?.pasteFromClipboard() },
                onReconnect = viewModel::reconnect,
                onFontSize = viewModel::setFontSize,
                onKeepScreenOn = viewModel::setKeepScreenOn,
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .consumeWindowInsets(padding)
                .windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars)),
        ) {
            Box(Modifier.weight(1f)) {
                TerminalHost(viewModel, state, onViewCreated = { terminalView = it })
                StatusOverlay(state.status, onReconnect = viewModel::reconnect, onBack = onBack)
            }
            ExtraKeysRow(state.modifiers, onKey = viewModel::pressExtraKey)
        }
    }
}

@Composable
private fun TerminalHost(
    viewModel: TerminalViewModel<RemoteTerminalSession>,
    state: TerminalUiState,
    onViewCreated: (RemoteTerminalView?) -> Unit,
) {
    val description = stringResource(R.string.terminal_description, state.sessionName)
    val callbacks = remember(viewModel) { ViewModelCallbacks(viewModel) }
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { context ->
            RemoteTerminalView(context, callbacks).also { view ->
                view.attach(viewModel.screen)
                onViewCreated(view)
                view.post { view.showKeyboard() }
            }
        },
        update = { view ->
            view.setFontSize(state.settings.fontSizeSp)
            view.keepScreenOn = state.settings.keepScreenOn
            view.contentDescription = description
        },
        onRelease = { view ->
            view.detach()
            onViewCreated(null)
        },
    )
}

/** Adaptador vista → ViewModel. */
private class ViewModelCallbacks(private val viewModel: TerminalViewModel<RemoteTerminalSession>) : RemoteTerminalView.Callbacks {
    override fun onText(text: CharSequence) = viewModel.typeText(text)
    override fun onCodePoint(codePoint: Int, ctrl: Boolean, alt: Boolean) = viewModel.typeHardwareCodePoint(codePoint, ctrl, alt)
    override fun onKeySequence(sequence: String) = viewModel.sendKeySequence(sequence)
    override fun onPaste(text: String) = viewModel.paste(text)
    override fun modifiers(): StickyModifiers = viewModel.state.value.modifiers
    override fun onSizeChanged(columns: Int, rows: Int) = viewModel.onViewResized(columns, rows)
    override fun onFontSizeChanged(sp: Int) = viewModel.setFontSize(sp)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TerminalTopBar(
    state: TerminalUiState,
    onBack: () -> Unit,
    onToggleKeyboard: () -> Unit,
    onPaste: () -> Unit,
    onReconnect: () -> Unit,
    onFontSize: (Int) -> Unit,
    onKeepScreenOn: (Boolean) -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    TopAppBar(
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = TerminalColors.Bar,
            titleContentColor = TerminalColors.OnBar,
            navigationIconContentColor = TerminalColors.OnBar,
            actionIconContentColor = TerminalColors.OnBar,
        ),
        title = {
            Column {
                Text(state.sessionName, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium)
                if (state.serverName.isNotEmpty()) {
                    Text(
                        state.serverName,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodySmall,
                        color = TerminalColors.OnBarSecondary,
                    )
                }
            }
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
            }
        },
        actions = {
            IconButton(onClick = onToggleKeyboard) {
                Icon(painterResource(R.drawable.ic_keyboard), contentDescription = stringResource(R.string.terminal_keyboard))
            }
            IconButton(onClick = onPaste) {
                Icon(painterResource(R.drawable.ic_paste), contentDescription = stringResource(R.string.terminal_paste))
            }
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.terminal_options))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.terminal_reconnect)) },
                        onClick = { menuOpen = false; onReconnect() },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.terminal_font_larger)) },
                        enabled = state.settings.fontSizeSp < TerminalSettings.MAX_FONT_SIZE_SP,
                        onClick = { onFontSize(state.settings.fontSizeSp + 1) },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.terminal_font_smaller)) },
                        enabled = state.settings.fontSizeSp > TerminalSettings.MIN_FONT_SIZE_SP,
                        onClick = { onFontSize(state.settings.fontSizeSp - 1) },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.terminal_keep_screen_on)) },
                        trailingIcon = { Checkbox(checked = state.settings.keepScreenOn, onCheckedChange = null) },
                        onClick = { onKeepScreenOn(!state.settings.keepScreenOn) },
                    )
                }
            }
        },
    )
}

/** Panel sobre el terminal mientras no está conectado (como el overlay de iOS). */
@Composable
private fun StatusOverlay(status: TerminalStatus, onReconnect: () -> Unit, onBack: () -> Unit) {
    if (status == TerminalStatus.Connected) return
    Box(
        Modifier
            .fillMaxSize()
            .background(TerminalColors.Background)
            .padding(24.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.widthIn(max = 480.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when (status) {
                is TerminalStatus.Connecting -> {
                    CircularProgressIndicator(color = TerminalColors.OnBar)
                    val text = if (status.attempt == 0) {
                        stringResource(R.string.terminal_connecting)
                    } else {
                        stringResource(R.string.terminal_reconnecting, status.attempt)
                    }
                    OverlayText(text)
                }
                is TerminalStatus.Disconnected -> {
                    OverlayTitle(stringResource(R.string.terminal_disconnected_title))
                    OverlayText(status.message.asString())
                    status.retryInSeconds?.let { OverlayText(stringResource(R.string.terminal_retrying_in, it)) }
                    Button(onClick = onReconnect) { Text(stringResource(R.string.terminal_reconnect)) }
                }
                TerminalStatus.SessionEnded -> {
                    OverlayTitle(stringResource(R.string.terminal_ended_title))
                    OverlayText(stringResource(R.string.terminal_ended))
                    Button(onClick = onReconnect) { Text(stringResource(R.string.terminal_reconnect)) }
                    OutlinedButton(onClick = onBack) { Text(stringResource(R.string.terminal_back_to_sessions)) }
                }
                TerminalStatus.Connected -> Unit
            }
        }
    }
}

@Composable
private fun OverlayTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleLarge,
        color = TerminalColors.OnBar,
        textAlign = TextAlign.Center,
        modifier = Modifier.semantics { heading() },
    )
}

@Composable
private fun OverlayText(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = TerminalColors.OnBarSecondary, textAlign = TextAlign.Center)
}
