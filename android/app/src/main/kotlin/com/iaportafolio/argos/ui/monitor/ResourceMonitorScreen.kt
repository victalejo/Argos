package com.iaportafolio.argos.ui.monitor

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.monitor.ResourceFormat
import com.iaportafolio.argos.core.monitor.ResourceProcess
import com.iaportafolio.argos.core.monitor.ResourceUsage
import com.iaportafolio.argos.core.monitor.ServerResourceSample
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import java.util.Locale

/** «Recursos del servidor»: se refresca solo mientras está a la vista. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ResourceMonitorScreen(viewModel: ResourceMonitorViewModel, onBack: () -> Unit) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(viewModel, lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { viewModel.pollWhileVisible() } }
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(stringResource(R.string.monitor_title))
                        Text(state.serverName, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back)) }
                },
            )
        },
    ) { padding ->
        val sample = state.sample
        when {
            sample != null -> SampleList(sample, state.cpuUsage, state.error, Modifier.padding(padding))
            state.error != null -> StatusMessage(
                icon = rememberVectorPainter(Icons.Filled.Warning),
                title = stringResource(R.string.monitor_failed),
                body = state.error,
                modifier = Modifier.padding(padding),
            )
            else -> ProgressMessage(stringResource(R.string.monitor_loading), Modifier.padding(padding))
        }
    }
}

@Composable
private fun SampleList(sample: ServerResourceSample, cpu: Double?, error: String?, modifier: Modifier) {
    LazyColumn(modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(16.dp)) } }
        item {
            val load = String.format(Locale.ROOT, "%.2f · %.2f · %.2f", sample.load1, sample.load5, sample.load15)
            InfoRow(stringResource(R.string.monitor_load, sample.cores), load)
        }
        item {
            UsageRow(
                stringResource(R.string.monitor_cpu),
                cpu?.let(ResourceFormat::percent) ?: "…",
                cpu ?: 0.0,
            )
        }
        item { UsageRow(stringResource(R.string.monitor_memory), usageText(sample.memory), sample.memory.fraction) }
        if (sample.swap.totalKB > 0) item { UsageRow(stringResource(R.string.monitor_swap), usageText(sample.swap), sample.swap.fraction) }
        item { UsageRow(stringResource(R.string.monitor_disk), usageText(sample.disk), sample.disk.fraction) }
        item { InfoRow(stringResource(R.string.monitor_uptime), ResourceFormat.uptime(sample.uptimeSeconds)) }
        item {
            Text(
                stringResource(R.string.monitor_processes),
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp),
            )
        }
        items(sample.topProcesses, key = { it.pid }) { ProcessRow(it) }
    }
}

private fun usageText(usage: ResourceUsage): String =
    "${ResourceFormat.kilobytes(usage.usedKB)} / ${ResourceFormat.kilobytes(usage.totalKB)} · ${ResourceFormat.percent(usage.fraction)}"

@Composable
private fun InfoRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun UsageRow(label: String, value: String, fraction: Double) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics(mergeDescendants = true) { contentDescription = "$label: $value" },
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            Text(value, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace)
        }
        LinearProgressIndicator(
            progress = { fraction.toFloat().coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth(),
            color = if (fraction >= HIGH_USAGE) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
        )
    }
}

@Composable
private fun ProcessRow(process: ResourceProcess) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(process.command, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text(
            String.format(Locale.ROOT, "%5.1f%% CPU  %4.1f%% MEM", process.cpuPercent, process.memPercent),
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
    }
    HorizontalDivider()
}

private const val HIGH_USAGE = 0.9
