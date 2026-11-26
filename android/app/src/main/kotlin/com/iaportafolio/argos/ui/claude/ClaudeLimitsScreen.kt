package com.iaportafolio.argos.ui.claude

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.usage.ClaudeLimitsStatus
import com.iaportafolio.argos.ui.common.asString

/** «Límites de Claude» de un servidor: explicación, activar/quitar y medidores por ventana. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ClaudeLimitsScreen(viewModel: ClaudeLimitsViewModel, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.refresh() }
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.claude_limits_title))
                        Text(state.serverName, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(stringResource(R.string.claude_limits_intro, state.serverName, ClaudeLimitsStatus.HIGH_FROM))
            Text(
                stringResource(R.string.claude_limits_explanation),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            SetupSection(state, viewModel)
            LimitsSection(state)
            state.notice?.let { Text(it.asString(), style = MaterialTheme.typography.bodyMedium) }
        }
    }
}

@Composable
private fun SetupSection(state: ClaudeLimitsUiState, viewModel: ClaudeLimitsViewModel) {
    when (val setup = state.setup) {
        ClaudeLimitsSetup.Checking -> CircularProgressIndicator(Modifier.size(24.dp))
        ClaudeLimitsSetup.Inactive -> Button(onClick = viewModel::activate, enabled = !state.isWorking) {
            Text(stringResource(R.string.claude_limits_activate))
        }
        ClaudeLimitsSetup.Active -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = ACTIVE_GREEN)
            Text(stringResource(R.string.claude_limits_active), color = ACTIVE_GREEN)
            OutlinedButton(onClick = viewModel::deactivate, enabled = !state.isWorking) {
                Text(stringResource(R.string.claude_limits_remove), color = MaterialTheme.colorScheme.error)
            }
        }
        is ClaudeLimitsSetup.NeedsRepair -> RepairSection(setup.previousMissing, state.isWorking, viewModel)
        is ClaudeLimitsSetup.Failed -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(setup.message, color = MaterialTheme.colorScheme.error)
            OutlinedButton(onClick = viewModel::refresh) { Text(stringResource(R.string.action_retry)) }
        }
    }
}

/** Puesta pero incompleta: «Reparar» reinstala el script; «Quitar» se niega si falta la copia del anterior. */
@Composable
private fun RepairSection(previousMissing: Boolean, isWorking: Boolean, viewModel: ClaudeLimitsViewModel) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = REPAIR_AMBER)
            Text(stringResource(R.string.claude_limits_needs_repair), color = REPAIR_AMBER)
        }
        Text(
            stringResource(if (previousMissing) R.string.claude_limits_repair_previous_missing else R.string.claude_limits_repair_outdated),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = viewModel::activate, enabled = !isWorking) { Text(stringResource(R.string.claude_limits_repair)) }
            OutlinedButton(onClick = viewModel::deactivate, enabled = !isWorking) {
                Text(stringResource(R.string.claude_limits_remove), color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun LimitsSection(state: ClaudeLimitsUiState) {
    val status = state.status
    when {
        status != null -> ClaudeLimitsMeters(status)
        state.setup == ClaudeLimitsSetup.Active || state.setup is ClaudeLimitsSetup.NeedsRepair -> Text(
            stringResource(R.string.claude_limits_no_data),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Verde de «Activo» (el tema no trae un color de éxito). */
private val ACTIVE_GREEN = Color(0xFF2E7D32)

/** Ámbar de «Hay que repararla». */
private val REPAIR_AMBER = Color(0xFFE65100)
