package com.iaportafolio.argos.ui.agents

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.ui.files.SafeMarkdown

/** Una fila del transcript (equivale a `TranscriptRow` de iOS). */
@Composable
internal fun TranscriptRow(row: AgentTranscriptRow, modifier: Modifier = Modifier) {
    when (row) {
        is AgentTranscriptRow.User -> UserBubble(row.text, modifier)
        // Sin cargador de imágenes y con enlaces confirmados: ver SafeMarkdown.
        is AgentTranscriptRow.Assistant -> SelectionContainer(modifier) { SafeMarkdown(row.text, Modifier.fillMaxWidth()) }
        is AgentTranscriptRow.Thinking -> Foldable(
            title = stringResource(R.string.agents_chat_thinking),
            icon = painterResource(R.drawable.ic_sparkles),
            modifier = modifier,
        ) { DetailText(row.text, monospace = false) }
        is AgentTranscriptRow.Tool -> Foldable(
            title = row.summary.ifEmpty { row.name },
            label = row.name.takeIf { row.summary.isNotEmpty() },
            icon = rememberVectorPainter(Icons.Filled.Build),
            modifier = modifier,
        ) { DetailText(row.detail, monospace = true) }
        is AgentTranscriptRow.ToolOutput -> Foldable(
            title = stringResource(if (row.isError) R.string.agents_chat_tool_error else R.string.agents_chat_tool_output),
            icon = rememberVectorPainter(if (row.isError) Icons.Filled.Warning else Icons.Filled.CheckCircle),
            isError = row.isError,
            startExpanded = row.isError,
            modifier = modifier,
        ) { DetailText(row.text, monospace = true) }
        is AgentTranscriptRow.TurnEnd -> TurnEnd(row, modifier)
        is AgentTranscriptRow.Failure -> ErrorLine(row.message, modifier)
    }
}

@Composable
private fun UserBubble(text: String, modifier: Modifier) {
    Box(modifier.fillMaxWidth().padding(start = 40.dp), contentAlignment = Alignment.CenterEnd) {
        SelectionContainer {
            Text(
                text,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier
                    .background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(14.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }
    }
}

/** Bloque plegable: la cabecera dice qué es y el botón no depende del color. */
@Composable
private fun Foldable(
    title: String,
    icon: Painter,
    modifier: Modifier,
    label: String? = null,
    isError: Boolean = false,
    startExpanded: Boolean = false,
    content: @Composable () -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(startExpanded) }
    val tint = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
    val state = stringResource(if (expanded) R.string.projects_group_expanded else R.string.projects_group_collapsed)
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button) { expanded = !expanded }
                .semantics { stateDescription = state }
                .padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            Column(Modifier.weight(1f)) {
                label?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = tint) }
                Text(
                    title,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = if (label != null) FontFamily.Monospace else null,
                    color = tint,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(20.dp),
            )
        }
        if (expanded) content()
    }
}

@Composable
internal fun DetailText(text: String, monospace: Boolean, modifier: Modifier = Modifier) {
    SelectionContainer(modifier) {
        Text(
            text,
            fontFamily = if (monospace) FontFamily.Monospace else null,
            fontSize = 12.sp,
            lineHeight = 16.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(8.dp))
                .padding(8.dp),
        )
    }
}

@Composable
private fun TurnEnd(row: AgentTranscriptRow.TurnEnd, modifier: Modifier) {
    val tint = if (row.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
    Column(modifier.widthIn(max = 640.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(
                if (row.isError) Icons.Filled.Warning else Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(14.dp),
            )
            val text = when {
                row.isError -> stringResource(R.string.agents_chat_turn_error)
                row.costUsd != null -> stringResource(R.string.agents_chat_turn_done_cost, row.costUsd)
                else -> stringResource(R.string.agents_chat_turn_done)
            }
            Text(text, style = MaterialTheme.typography.labelSmall, color = tint)
        }
        row.errorText?.let { ErrorLine(it, Modifier) }
    }
}

@Composable
private fun ErrorLine(message: String, modifier: Modifier) {
    SelectionContainer(modifier) {
        Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
    }
}
