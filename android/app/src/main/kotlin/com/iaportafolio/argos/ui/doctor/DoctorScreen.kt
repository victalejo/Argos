package com.iaportafolio.argos.ui.doctor

import android.content.ClipData
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.doctor.DoctorCheck
import com.iaportafolio.argos.core.doctor.DoctorCheckID
import com.iaportafolio.argos.core.doctor.DoctorFix
import com.iaportafolio.argos.core.doctor.DoctorResult
import com.iaportafolio.argos.core.doctor.DoctorStatus
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import kotlinx.coroutines.launch

/** «Doctor del servidor»: comprobaciones con su estado, arreglos de un toque y «Copiar diagnóstico». */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DoctorScreen(viewModel: DoctorViewModel, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    var reportOpen by rememberSaveable { mutableStateOf(false) }
    val copied = stringResource(R.string.doctor_copied)
    val copy = { text: String ->
        scope.launch {
            clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Argos", text)))
            snackbar.showSnackbar(copied)
        }
        Unit
    }
    state.fixError?.let { message ->
        LaunchedEffect(message) {
            snackbar.showSnackbar(message)
            viewModel.fixErrorShown()
        }
    }
    if (reportOpen) {
        ReportDialog(
            includePersonalData = state.includePersonalData,
            onIncludePersonalData = viewModel::setIncludePersonalData,
            onCopy = {
                reportOpen = false
                copy(viewModel.report())
            },
            onDismiss = { reportOpen = false },
        )
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.doctor_title))
                        Text(state.serverName, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back)) }
                },
                actions = {
                    IconButton(onClick = { reportOpen = true }) {
                        Icon(painterResource(R.drawable.ic_copy), contentDescription = stringResource(R.string.doctor_copy_report))
                    }
                    if (state.isRunning) {
                        CircularProgressIndicator(Modifier.padding(12.dp).size(24.dp), strokeWidth = 2.dp)
                    } else {
                        IconButton(onClick = viewModel::run) {
                            Icon(Icons.Filled.Refresh, contentDescription = stringResource(R.string.doctor_recheck))
                        }
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        when (val load = state.load) {
            is DoctorLoad.Loaded -> CheckList(load.result, state.fixing, viewModel::apply, copy, Modifier.padding(padding))
            is DoctorLoad.Failed -> StatusMessage(
                icon = rememberVectorPainter(Icons.Filled.Warning),
                title = stringResource(R.string.doctor_failed),
                body = load.message,
                modifier = Modifier.padding(padding),
                actions = { OutlinedButton(onClick = viewModel::run) { Text(stringResource(R.string.doctor_recheck)) } },
            )
            DoctorLoad.Loading -> ProgressMessage(stringResource(R.string.doctor_loading), Modifier.padding(padding))
        }
    }
}

@Composable
private fun CheckList(
    result: DoctorResult,
    fixing: DoctorCheckID?,
    onApply: (DoctorFix, DoctorCheckID) -> Unit,
    onCopy: (String) -> Unit,
    modifier: Modifier,
) {
    // Primero lo que necesita atención; dentro, el orden del evaluador.
    val ordered = result.checks.sortedByDescending { it.status.severity }
    LazyColumn(modifier) {
        item {
            Text(
                result.summary,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            )
            HorizontalDivider()
        }
        items(ordered, key = { it.id.name }) { check ->
            CheckRow(check, isFixing = fixing == check.id, fixEnabled = fixing == null, onApply = onApply, onCopy = onCopy)
            HorizontalDivider()
        }
    }
}

@Composable
private fun CheckRow(
    check: DoctorCheck,
    isFixing: Boolean,
    fixEnabled: Boolean,
    onApply: (DoctorFix, DoctorCheckID) -> Unit,
    onCopy: (String) -> Unit,
) {
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val (icon, tint) = statusIcon(check.status)
        Icon(icon, contentDescription = check.status.label, tint = tint, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(check.title, style = MaterialTheme.typography.titleSmall)
            Text(check.detail, style = MaterialTheme.typography.bodyMedium)
            when (val fix = check.fix) {
                is DoctorFix.CopyCommand -> {
                    SelectionContainer {
                        Text(fix.command, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                    }
                    TextButton(onClick = { onCopy(fix.command) }) { Text(stringResource(R.string.doctor_copy_command)) }
                }
                is DoctorFix.InstallClaudeHooks, is DoctorFix.InstallPortsSkill -> FixButton(fix, check.id, isFixing, fixEnabled, onApply)
                null -> Unit
            }
        }
    }
}

@Composable
private fun FixButton(fix: DoctorFix, id: DoctorCheckID, isFixing: Boolean, enabled: Boolean, onApply: (DoctorFix, DoctorCheckID) -> Unit) {
    val label = when (fix) {
        is DoctorFix.InstallClaudeHooks -> if (fix.isUpdate) R.string.doctor_fix_update_hooks else R.string.doctor_fix_install_hooks
        is DoctorFix.InstallPortsSkill -> if (fix.isUpdate) R.string.doctor_fix_update_skill else R.string.doctor_fix_install_skill
        is DoctorFix.CopyCommand -> return
    }
    OutlinedButton(onClick = { onApply(fix, id) }, enabled = enabled) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (isFixing) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Text(stringResource(label))
        }
    }
}

@Composable
private fun statusIcon(status: DoctorStatus): Pair<ImageVector, Color> = when (status) {
    DoctorStatus.OK -> Icons.Filled.CheckCircle to MaterialTheme.colorScheme.primary
    DoctorStatus.WARNING -> Icons.Filled.Warning to MaterialTheme.colorScheme.tertiary
    DoctorStatus.PROBLEM -> Icons.Filled.Warning to MaterialTheme.colorScheme.error
    DoctorStatus.UNKNOWN -> Icons.Filled.Info to MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
private fun ReportDialog(
    includePersonalData: Boolean,
    onIncludePersonalData: (Boolean) -> Unit,
    onCopy: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.doctor_copy_report)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.doctor_report_explanation))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = includePersonalData, onCheckedChange = onIncludePersonalData)
                    Text(stringResource(R.string.doctor_report_personal))
                }
                Text(stringResource(R.string.doctor_report_review), style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = { TextButton(onClick = onCopy) { Text(stringResource(R.string.doctor_report_copy)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}
