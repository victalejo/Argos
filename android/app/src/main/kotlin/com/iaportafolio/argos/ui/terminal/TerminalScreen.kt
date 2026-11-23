package com.iaportafolio.argos.ui.terminal

import androidx.activity.compose.LocalActivity
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
import androidx.compose.foundation.layout.size
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
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.TerminalSettings
import com.iaportafolio.argos.terminal.RemoteTerminalSession
import com.iaportafolio.argos.terminal.RemoteTerminalView
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.asString

/**
 * Terminal en vivo de una sesión tmux (equivale a `TerminalScreen` de iOS): barra con el nombre
 * de la sesión, las ventanas de tmux como pestañas ([TerminalWindowBar]), el emulador y la fila
 * de teclas extra pegada al teclado.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    viewModel: TerminalViewModel<RemoteTerminalSession>,
    onBack: () -> Unit,
    /**
     * Abrir el teclado al entrar. En la pantalla de proyecto va a `false`: el teclado tapaba
     * las pestañas (Terminal · Archivos · Agentes); se abre al tocar el terminal.
     */
    autoShowKeyboard: Boolean = true,
    /** Pestañas de las ventanas tmux; `null` = sin barra de ventanas. */
    windows: TerminalWindowsViewModel? = null,
    /**
     * `false` cuando otro (la pantalla del proyecto, con [TerminalConnectionEffect]) mantiene el
     * attach: así cambiar de pestaña no hace detach ni repinta.
     */
    ownsConnection: Boolean = true,
    /**
     * La sesión pertenece a un proyecto: con la sesión desaparecida del servidor se ofrece
     * «Iniciar de nuevo» (arranca el proyecto y reconecta). `null` = sesión suelta («Reconectar»).
     */
    restart: SessionRestart? = null,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val windowsState = windows?.state?.collectAsStateWithLifecycle()?.value
    val snackbar = remember { SnackbarHostState() }
    if (windows != null) {
        // Solo se sondea con la pantalla visible; al volver se relee al instante.
        val lifecycle = LocalLifecycleOwner.current.lifecycle
        LaunchedEffect(windows, lifecycle) {
            lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { windows.pollWhileVisible() }
        }
        MessageEffect(windowsState?.message, snackbar, windows::messageShown)
        windowsState?.closing?.let { closing ->
            CloseWindowDialog(closing, onConfirm = windows::confirmClose, onDismiss = windows::dismissClose)
        }
        windowsState?.renaming?.let { rename ->
            RenameWindowDialog(rename, onText = windows::onRenameText, onConfirm = windows::confirmRename, onDismiss = windows::dismissRename)
        }
    }
    var terminalView by remember { mutableStateOf<RemoteTerminalView?>(null) }
    val context = LocalContext.current
    val attach = rememberTerminalAttachLaunchers(viewModel)

    if (ownsConnection) TerminalConnectionEffect(viewModel)

    Scaffold(
        containerColor = TerminalColors.Background,
        contentWindowInsets = WindowInsets(0),
        // Sobre el teclado: en un terminal casi siempre está abierto.
        snackbarHost = { SnackbarHost(snackbar, Modifier.windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars))) },
        topBar = {
            TerminalTopBar(
                state = state,
                onBack = onBack,
                onToggleKeyboard = { terminalView?.toggleKeyboard() },
                // Una captura copiada se sube y se teclea su ruta; el texto se pega como siempre.
                onPaste = { if (!pasteImageIfAny(context, viewModel)) terminalView?.pasteFromClipboard() },
                attach = if (viewModel.canAttach) attach else null,
                panes = windows,
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
            // La barra va SIEMPRE (salvo sesión terminada o inexistente): antes solo
            // salía cuando el listado de tmux ya había llegado, y un `list-windows`
            // lento o fallido la dejaba invisible — sin pestañas y sin el «+» para
            // crear ventanas. Sin ventanas leídas, la propia barra muestra
            // «cargando» o el error.
            if (windows != null && windowsState != null && !state.status.isFinished) {
                TerminalWindowBar(
                    state = windowsState,
                    onSelect = windows::select,
                    onNew = windows::newWindow,
                    onNewAgent = windows::newAgentWindow,
                    onClose = { windows.requestClose(it.index) },
                    onRename = windows::requestRename,
                    onColor = windows::setColor,
                    onRetry = windows::refreshWindowsNow,
                )
            }
            Box(Modifier.weight(1f)) {
                TerminalHost(viewModel, state, onViewCreated = { terminalView = it }, autoShowKeyboard = autoShowKeyboard)
                StatusOverlay(state.status, onReconnect = viewModel::reconnect, onBack = onBack, restart = restart)
                NoticeBanner(state.notice, onShown = viewModel::noticeShown, modifier = Modifier.align(Alignment.TopCenter))
            }
            ExtraKeysRow(state.modifiers, onKey = viewModel::pressExtraKey, onHideKeyboard = { terminalView?.hideKeyboard() })
        }
    }
}

/**
 * Engancha el terminal mientras este punto de la composición esté vivo y su pantalla iniciada.
 * La pantalla también se detiene al navegar dentro de la app: solo es segundo plano si se detuvo
 * la Activity. La sesión sigue viva en tmux en cualquier caso.
 */
@Composable
fun TerminalConnectionEffect(viewModel: TerminalViewModel<RemoteTerminalSession>) {
    val activityLifecycle = (LocalActivity.current as? LifecycleOwner)?.lifecycle
    LifecycleStartEffect(viewModel) {
        viewModel.onStart()
        onStopOrDispose {
            if (activityLifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == false) {
                viewModel.onStop()
            } else {
                viewModel.onLeave()
            }
        }
    }
}

@Composable
internal fun TerminalHost(
    viewModel: TerminalViewModel<RemoteTerminalSession>,
    state: TerminalUiState,
    onViewCreated: (RemoteTerminalView?) -> Unit,
    autoShowKeyboard: Boolean,
) {
    val description = stringResource(R.string.terminal_description, state.sessionName)
    val callbacks = remember(viewModel) { ViewModelCallbacks(viewModel) }
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { context ->
            RemoteTerminalView(context, callbacks).also { view ->
                view.attach(viewModel.screen)
                onViewCreated(view)
                if (autoShowKeyboard) view.post { view.showKeyboard() }
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
    attach: TerminalAttachLaunchers?,
    panes: TerminalWindowsViewModel?,
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
            if (attach != null) AttachButton(attach)
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
                    if (panes != null) PaneMenuItems(panes) { menuOpen = false }
                }
            }
        },
    )
}

/** «Iniciar de nuevo» la sesión de un proyecto que desapareció del servidor. */
data class SessionRestart(val isStarting: Boolean, val onRestart: () -> Unit)

/** Sesión cerrada o inexistente: ya no hay ventanas que mostrar. */
private val TerminalStatus.isFinished: Boolean
    get() = this == TerminalStatus.SessionEnded || this is TerminalStatus.SessionMissing

/** Panel sobre el terminal mientras no está conectado (como el overlay de iOS). */
@Composable
private fun StatusOverlay(status: TerminalStatus, onReconnect: () -> Unit, onBack: () -> Unit, restart: SessionRestart?) {
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
                is TerminalStatus.SessionMissing -> SessionMissingPanel(status, onReconnect, onBack, restart)
                TerminalStatus.Connected -> Unit
            }
        }
    }
}

/**
 * La sesión ya no existe en el servidor (como `TerminalSessionMissingPanel` de iOS): en vez de
 * «Reconectar» (que volvería a fallar) se ofrece iniciar el proyecto de nuevo.
 */
@Composable
private fun SessionMissingPanel(
    status: TerminalStatus.SessionMissing,
    onReconnect: () -> Unit,
    onBack: () -> Unit,
    restart: SessionRestart?,
) {
    OverlayTitle(stringResource(R.string.terminal_session_missing_title))
    OverlayText(status.message.asString())
    if (restart != null) {
        Button(onClick = restart.onRestart, enabled = !restart.isStarting) {
            if (restart.isStarting) {
                CircularProgressIndicator(Modifier.padding(end = 8.dp).size(18.dp), strokeWidth = 2.dp)
            }
            Text(stringResource(R.string.terminal_session_restart))
        }
    } else {
        Button(onClick = onReconnect) { Text(stringResource(R.string.terminal_reconnect)) }
    }
    OutlinedButton(onClick = onBack) { Text(stringResource(R.string.terminal_back_to_sessions)) }
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
