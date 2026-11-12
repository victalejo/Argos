package com.iaportafolio.argos.ui.ports

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.ports.ActivePortForward
import com.iaportafolio.argos.core.ports.ListeningPort
import com.iaportafolio.argos.core.ports.PortForwardIdlePolicy
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.asString

/**
 * «Puertos» de un servidor (equivale al popover del Mac y a la hoja de iOS): reenvía un puerto del
 * servidor a `localhost` del teléfono y lo abre en el navegador.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PortForwardsScreen(viewModel: PortForwardsViewModel, state: PortForwardsUiState, onBack: () -> Unit) {
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, viewModel::messageShown)
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.openRequests.collect { url -> openInBrowser(context, url) }
    }
    // Solo con la pantalla delante: con el navegador abierto no se consulta el servidor.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(viewModel, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { viewModel.pollWhileVisible() }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.ports_title))
                        if (state.serverName.isNotEmpty()) {
                            Text(
                                stringResource(R.string.ports_subtitle, state.serverName),
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
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
                    IconButton(onClick = viewModel::refresh) {
                        Icon(Icons.Filled.Refresh, contentDescription = stringResource(R.string.ports_refresh))
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (state.forwards.isNotEmpty()) {
                item { SectionTitle(stringResource(R.string.ports_forwarded)) }
                items(state.forwards, key = { "f" + it.id }) { forward ->
                    ForwardRow(forward, busy = forward.remotePort in state.busyPorts, viewModel)
                }
                item {
                    Text(
                        stringResource(R.string.ports_forwarded_footer),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }
                item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            }
            item { SectionTitle(stringResource(R.string.ports_listening, state.serverName)) }
            when {
                !state.hasLoaded -> item {
                    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
                state.listError != null -> item { Hint(state.listError.asString()) }
                state.visiblePorts.isEmpty() -> item { Hint(stringResource(R.string.ports_none)) }
                else -> items(state.visiblePorts, key = { "l" + it.port }) { port ->
                    ListeningRow(port, state, viewModel)
                }
            }
            if (state.hiddenSystemPortCount > 0) {
                item {
                    ListItem(
                        headlineContent = { Text(stringResource(R.string.ports_show_system, state.hiddenSystemPortCount)) },
                        trailingContent = {
                            Switch(checked = state.showsSystemPorts, onCheckedChange = viewModel::setShowSystemPorts)
                        },
                    )
                }
            }
            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item { ManualPort(state, viewModel) }
            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            item { IdleLimit(state, viewModel) }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun Hint(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun ForwardRow(forward: ActivePortForward, busy: Boolean, viewModel: PortForwardsViewModel) {
    ListItem(
        headlineContent = { Text(forward.localAddress, fontFamily = FontFamily.Monospace) },
        supportingContent = {
            val label = if (forward.isReconnecting) R.string.ports_reconnecting else R.string.ports_to_remote
            Text(stringResource(label, forward.remotePort.toString()))
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { viewModel.open(forward) }, enabled = !forward.isReconnecting) {
                    Text(stringResource(R.string.ports_open))
                }
                if (busy) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    IconButton(onClick = { viewModel.stop(forward) }) {
                        Icon(
                            Icons.Filled.Close,
                            contentDescription = stringResource(R.string.ports_stop, forward.remotePort.toString()),
                        )
                    }
                }
            }
        },
    )
}

@Composable
private fun ListeningRow(port: ListeningPort, state: PortForwardsUiState, viewModel: PortForwardsViewModel) {
    val forwarded = state.forwardFor(port.port) != null
    ListItem(
        // Sin separador de miles: un puerto no es una cantidad.
        headlineContent = { Text(port.port.toString(), fontFamily = FontFamily.Monospace) },
        supportingContent = (port.processName ?: port.targetHost.takeIf { it != "localhost" })?.let { detail ->
            { Text(detail, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        },
        trailingContent = {
            if (port.port in state.busyPorts) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                FilledTonalButton(onClick = { viewModel.startAndOpen(port) }) {
                    Text(stringResource(if (forwarded) R.string.ports_open else R.string.ports_forward_open))
                }
            }
        },
    )
}

@Composable
private fun ManualPort(state: PortForwardsUiState, viewModel: PortForwardsViewModel) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = state.manualPort,
                onValueChange = viewModel::setManualPort,
                label = { Text(stringResource(R.string.ports_manual)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { viewModel.startManual() }),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(12.dp))
            FilledTonalButton(onClick = viewModel::startManual, enabled = state.canStartManual) {
                Text(stringResource(R.string.ports_forward))
            }
        }
        Text(
            stringResource(R.string.ports_manual_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Cierre automático: minutos sin conexiones tras los que se cierra cada túnel. */
@Composable
private fun IdleLimit(state: PortForwardsUiState, viewModel: PortForwardsViewModel) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.ports_idle_title), style = MaterialTheme.typography.titleSmall)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            PortForwardIdlePolicy.options.forEach { minutes ->
                FilterChip(
                    selected = state.idleMinutes == minutes,
                    onClick = { viewModel.setIdleMinutes(minutes) },
                    label = {
                        Text(
                            if (minutes == 0) stringResource(R.string.ports_idle_never)
                            else stringResource(R.string.ports_idle_minutes, minutes),
                        )
                    },
                )
            }
        }
        Text(
            stringResource(R.string.ports_idle_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Abre la web del túnel en el navegador del sistema. */
internal fun openInBrowser(context: Context, url: String) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, url.toUri()))
    } catch (e: ActivityNotFoundException) {
        ArgosLog.error(ArgosLog.TAG_SSH, "sin navegador para $url", e)
    }
}
