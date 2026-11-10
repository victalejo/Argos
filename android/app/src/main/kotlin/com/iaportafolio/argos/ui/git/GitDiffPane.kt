package com.iaportafolio.argos.ui.git

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitChangeKind
import com.iaportafolio.argos.core.git.GitDiffLine
import com.iaportafolio.argos.core.git.GitDiffLineKind
import com.iaportafolio.argos.core.git.GitFileDiff
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString

/** Colores de git: los mismos tonos que el Mac (verde añadido, rojo borrado…), legibles en claro y oscuro. */
internal object GitColors {
    val added = Color(0xFF2EA043)
    val removed = Color(0xFFE5534B)
    val modified = Color(0xFFD29922)
    val renamed = Color(0xFF4A8FE7)
    val conflicted = Color(0xFFDB61A2)

    fun kind(kind: GitChangeKind): Color = when (kind) {
        GitChangeKind.MODIFIED, GitChangeKind.TYPE_CHANGED -> modified
        GitChangeKind.ADDED, GitChangeKind.UNTRACKED -> added
        GitChangeKind.DELETED -> removed
        GitChangeKind.RENAMED, GitChangeKind.COPIED -> renamed
        GitChangeKind.CONFLICTED -> conflicted
    }
}

/** Diff del archivo elegido. [onClose] (móvil) muestra «atrás» para volver a la lista. */
@Composable
internal fun DiffPane(state: GitChangesUiState, onClose: (() -> Unit)?, modifier: Modifier) {
    val change = state.selectedChange
    Column(modifier) {
        if (change != null) {
            DiffTopBar(change.fileName, change.directory, (state.diff as? GitDiffLoad.Loaded)?.diff, onClose)
            HorizontalDivider()
        }
        when (val diff = state.diff) {
            GitDiffLoad.None -> StatusMessage(
                icon = painterResource(R.drawable.ic_file_text),
                title = stringResource(R.string.git_pick_file),
            )
            GitDiffLoad.Loading -> ProgressMessage(stringResource(R.string.git_diff_loading))
            is GitDiffLoad.Failed -> StatusMessage(
                icon = rememberVectorPainter(Icons.Filled.Warning),
                title = stringResource(R.string.git_failed_title),
                body = diff.message.asString(),
            )
            is GitDiffLoad.Loaded -> DiffContent(diff.diff)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DiffTopBar(name: String, directory: String, diff: GitFileDiff?, onClose: (() -> Unit)?) {
    TopAppBar(
        windowInsets = WindowInsets(0),
        title = {
            Column {
                Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val stat = diff?.let { stringResource(R.string.git_diff_stat, it.additions, it.deletions) }
                val subtitle = listOfNotNull(stat, directory.ifEmpty { null }).joinToString(" · ")
                if (subtitle.isNotEmpty()) {
                    Text(subtitle, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, style = MaterialTheme.typography.bodySmall)
                }
            }
        },
        navigationIcon = {
            onClose?.let {
                IconButton(onClick = it) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
                }
            }
        },
    )
}

@Composable
private fun DiffContent(diff: GitFileDiff) {
    when {
        diff.isBinary -> StatusMessage(icon = painterResource(R.drawable.ic_file), title = stringResource(R.string.git_diff_binary))
        !diff.hasContent -> StatusMessage(icon = painterResource(R.drawable.ic_file_text), title = stringResource(R.string.git_diff_empty))
        else -> Column {
            if (diff.truncated) {
                Text(
                    stringResource(R.string.git_diff_truncated),
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                )
            }
            // En una pantalla estrecha las líneas largas se parten: más legible que desplazar en horizontal.
            LazyColumn(Modifier.fillMaxWidth()) {
                // Las cabeceras previas al primer hunk (`index`, `---`, `+++`) no aportan en el móvil.
                items(diff.lines.filter { it.kind != GitDiffLineKind.META }, key = { it.id }) { DiffLineRow(it) }
            }
        }
    }
}

@Composable
private fun DiffLineRow(line: GitDiffLine) {
    val (background, prefix) = when (line.kind) {
        GitDiffLineKind.ADDED -> GitColors.added.copy(alpha = 0.16f) to "+"
        GitDiffLineKind.REMOVED -> GitColors.removed.copy(alpha = 0.16f) to "-"
        GitDiffLineKind.HUNK -> MaterialTheme.colorScheme.surfaceContainerHigh to ""
        else -> Color.Transparent to " "
    }
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Row(Modifier.fillMaxWidth().background(background)) {
        if (line.kind == GitDiffLineKind.HUNK || line.kind == GitDiffLineKind.NO_NEWLINE) {
            DiffText(line.text, muted, Modifier.weight(1f).padding(horizontal = 8.dp, vertical = 2.dp))
            return@Row
        }
        LineNumber(line.oldNumber)
        LineNumber(line.newNumber)
        DiffText("$prefix ${line.text}", MaterialTheme.colorScheme.onSurface, Modifier.weight(1f).padding(end = 8.dp))
    }
}

@Composable
private fun LineNumber(number: Int?) {
    Text(
        number?.toString().orEmpty(),
        fontFamily = FontFamily.Monospace,
        fontSize = DIFF_FONT_SIZE,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.End,
        modifier = Modifier.width(40.dp).padding(end = 6.dp),
    )
}

@Composable
private fun DiffText(text: String, color: Color, modifier: Modifier) {
    Text(text, fontFamily = FontFamily.Monospace, fontSize = DIFF_FONT_SIZE, color = color, modifier = modifier)
}

private val DIFF_FONT_SIZE = 12.sp
