package com.iaportafolio.argos.ui.monitor

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.monitor.ServerMemoryPressureLevel
import com.iaportafolio.argos.core.monitor.ServerMemoryWarning
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.asString

/** Título del aviso (sin aviso en nivel normal: el título de alto sirve de reserva). */
fun ServerMemoryWarning.titleText(): UiText = when (level) {
    ServerMemoryPressureLevel.CRITICAL -> UiText.res(R.string.memory_pressure_critical_title)
    ServerMemoryPressureLevel.HIGH, ServerMemoryPressureLevel.NORMAL -> UiText.res(R.string.memory_pressure_high_title)
}

/** Mensaje del aviso: cita los procesos de Claude cuando los hay. */
fun ServerMemoryWarning.messageText(): UiText = citedClaudeProcesses
    ?.let { claude -> UiText.Plural(R.plurals.memory_pressure_message_claude, claude, listOf(usedPercent, claude)) }
    ?: UiText.res(R.string.memory_pressure_message, usedPercent)

/** Colores del aviso alto: ámbar legible en claro y oscuro (el tema no trae un color de aviso). */
private val WARNING_LIGHT = Color(0xFFFFE0B2) to Color(0xFF4E2F00)
private val WARNING_DARK = Color(0xFF4A3200) to Color(0xFFFFDDB3)

/** Tarjeta sobre la lista de proyectos: crítico con el color de error del tema, alto en ámbar. */
@Composable
fun ServerMemoryBanner(warning: ServerMemoryWarning, modifier: Modifier = Modifier) {
    val (container, content) = when (warning.level) {
        ServerMemoryPressureLevel.CRITICAL -> MaterialTheme.colorScheme.errorContainer to MaterialTheme.colorScheme.onErrorContainer
        ServerMemoryPressureLevel.HIGH, ServerMemoryPressureLevel.NORMAL ->
            if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) WARNING_DARK else WARNING_LIGHT
    }
    Row(
        modifier
            .fillMaxWidth()
            .background(container)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Warning, contentDescription = null, tint = content)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(warning.titleText().asString(), style = MaterialTheme.typography.titleSmall, color = content)
            Text(warning.messageText().asString(), style = MaterialTheme.typography.bodySmall, color = content)
        }
    }
}

/** Confirmación antes de arrancar otra sesión con el servidor casi sin memoria. */
@Composable
fun ServerMemoryStartDialog(warning: ServerMemoryWarning, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
        title = { Text(warning.titleText().asString()) },
        text = { Text(warning.messageText().asString()) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(stringResource(R.string.memory_pressure_start_anyway), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) } },
    )
}
