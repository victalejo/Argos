package com.iaportafolio.argos.ui.agents

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.terminal.RemoteTerminalSession
import com.iaportafolio.argos.terminal.RemoteTerminalView
import com.iaportafolio.argos.ui.common.asString
import com.iaportafolio.argos.ui.files.copyToClipboard
import com.iaportafolio.argos.ui.terminal.ExtraKeysRow
import com.iaportafolio.argos.ui.terminal.TerminalColors
import com.iaportafolio.argos.ui.terminal.TerminalHost
import com.iaportafolio.argos.ui.terminal.TerminalStatus
import com.iaportafolio.argos.ui.terminal.TerminalViewModel

/**
 * Login guiado de Claude en el servidor: pasos nativos arriba y el terminal real abajo, por si
 * el texto del CLI cambia. A diferencia de un terminal normal, NO se desengancha al pasar a
 * segundo plano: el usuario va al navegador a autorizar y `claude auth login` debe seguir
 * esperando el código. Se cierra solo al salir de la pantalla.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentLoginScreen(
    login: AgentLoginViewModel,
    terminal: TerminalViewModel<RemoteTerminalSession>,
    onClose: () -> Unit,
) {
    val state by login.state.collectAsStateWithLifecycle()
    val terminalState by terminal.state.collectAsStateWithLifecycle()
    var terminalView by remember { mutableStateOf<RemoteTerminalView?>(null) }
    val close by rememberUpdatedState(onClose)

    LaunchedEffect(login, terminal) { if (login.claimTerminalStart()) terminal.onStart() }
    LaunchedEffect(login) { login.events.collect { close() } }
    val status = terminalState.status
    val ended = status == TerminalStatus.SessionEnded || (status is TerminalStatus.Disconnected && status.retryInSeconds == null)
    LaunchedEffect(ended) { if (ended) login.onTerminalEnded() }

    Scaffold(
        contentWindowInsets = WindowInsets(0),
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.agents_login_title), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            stringResource(R.string.agents_login_subtitle, state.serverName),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
                actions = {
                    IconButton(onClick = { terminalView?.toggleKeyboard() }) {
                        Icon(painterResource(R.drawable.ic_keyboard), contentDescription = stringResource(R.string.terminal_keyboard))
                    }
                    IconButton(onClick = { terminalView?.pasteFromClipboard() }) {
                        Icon(painterResource(R.drawable.ic_paste), contentDescription = stringResource(R.string.terminal_paste))
                    }
                },
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
            LoginSteps(
                state = state,
                onSubmitCode = { code -> login.submitCode(code)?.let(terminal::sendInput) },
                onRestart = {
                    login.restart()
                    terminal.reconnect()
                },
                modifier = Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
            )
            Box(Modifier.weight(1f).background(TerminalColors.Background)) {
                TerminalHost(terminal, terminalState, onViewCreated = { terminalView = it }, autoShowKeyboard = false)
                TerminalStatusOverlay(status)
            }
            ExtraKeysRow(terminalState.modifiers, onKey = terminal::pressExtraKey)
        }
    }
}

@Composable
private fun LoginSteps(
    state: AgentLoginUiState,
    onSubmitCode: (String) -> Unit,
    onRestart: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        AuthorizeStep(state.authorizationUrl, state.phase)
        CodeStep(state, onSubmitCode)
        Outcome(state.phase, onRestart)
    }
}

@Composable
private fun AuthorizeStep(url: String?, phase: AgentLoginPhase) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    var confirming by rememberSaveable { mutableStateOf(false) }
    val copied = stringResource(R.string.agents_login_copied)
    val clipLabel = stringResource(R.string.agents_login_clip_label)

    StepTitle(stringResource(R.string.agents_login_step_open))
    if (url == null) {
        if (phase == AgentLoginPhase.Starting) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text(stringResource(R.string.agents_login_preparing), style = MaterialTheme.typography.bodyMedium)
            }
        }
        return
    }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = { confirming = true }) { Text(stringResource(R.string.agents_login_open)) }
        TextButton(onClick = {
            copyToClipboard(context, clipLabel, url)
            Toast.makeText(context, copied, Toast.LENGTH_SHORT).show()
        }) { Text(stringResource(R.string.agents_login_copy)) }
    }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text(stringResource(R.string.files_link_title)) },
            text = { Text(url) },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    try {
                        uriHandler.openUri(url)
                    } catch (error: IllegalArgumentException) {
                        ArgosLog.warn(ArgosLog.TAG_UI, "Sin navegador para abrir el enlace de autorización", error)
                    }
                }) { Text(stringResource(R.string.files_link_open)) }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

@Composable
private fun CodeStep(state: AgentLoginUiState, onSubmitCode: (String) -> Unit) {
    // Sin guardar en el estado de instancia: es de un solo uso y no debe sobrevivir a la app.
    var code by remember { mutableStateOf("") }
    val submit = {
        onSubmitCode(code)
        code = ""
    }
    StepTitle(stringResource(R.string.agents_login_step_code))
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = code,
            onValueChange = { code = it },
            label = { Text(stringResource(R.string.agents_login_code)) },
            singleLine = true,
            enabled = state.canSubmitCode,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (code.isNotBlank()) submit() }),
            modifier = Modifier.weight(1f),
        )
        Button(onClick = submit, enabled = state.canSubmitCode && code.isNotBlank()) {
            Text(stringResource(R.string.agents_login_confirm))
        }
    }
}

@Composable
private fun Outcome(phase: AgentLoginPhase, onRestart: () -> Unit) {
    val live = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite }
    when (phase) {
        AgentLoginPhase.Starting, AgentLoginPhase.Authorize -> Unit
        AgentLoginPhase.Verifying -> Row(live, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            Text(stringResource(R.string.agents_login_verifying), style = MaterialTheme.typography.bodyMedium)
        }
        is AgentLoginPhase.Success -> Text(
            phase.detail?.let { stringResource(R.string.agents_login_success_detail, it) } ?: stringResource(R.string.agents_login_success),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
            modifier = live,
        )
        is AgentLoginPhase.Failed -> Column(live, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(phase.message.asString(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
            OutlinedButton(onClick = onRestart) { Text(stringResource(R.string.agents_login_restart)) }
        }
    }
}

@Composable
private fun StepTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
}

/** Lo que aún no pinta el terminal. Al terminar el comando se deja ver su última salida. */
@Composable
private fun TerminalStatusOverlay(status: TerminalStatus) {
    val text = when (status) {
        is TerminalStatus.Connecting -> stringResource(R.string.agents_login_terminal_starting)
        is TerminalStatus.Disconnected -> status.message.asString()
        TerminalStatus.Connected, TerminalStatus.SessionEnded -> return
    }
    Box(
        Modifier.fillMaxSize().background(TerminalColors.Background).padding(24.dp).semantics { liveRegion = LiveRegionMode.Polite },
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = TerminalColors.OnBarSecondary, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodyMedium)
    }
}
