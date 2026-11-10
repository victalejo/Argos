package com.iaportafolio.argos.ui.git

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitRepoSummary

/**
 * Insignia git de una fila de proyecto (port de `GitSummaryBadge` de Apple): ✎N archivos
 * cambiados (naranja), ↑N por subir (azul), ↓N por traer (morado). Nada si está limpio y al día.
 */
@Composable
fun GitSummaryBadge(summary: GitRepoSummary?, modifier: Modifier = Modifier) {
    if (summary == null || !summary.isNoteworthy) return
    Row(
        modifier.clearAndSetSemantics { contentDescription = summary.label },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (summary.changedCount > 0) Part(stringResource(R.string.git_badge_changed, summary.changedCount), BADGE_CHANGED)
        if (summary.branch.ahead > 0) Part(stringResource(R.string.git_badge_ahead, summary.branch.ahead), BADGE_AHEAD)
        if (summary.branch.behind > 0) Part(stringResource(R.string.git_badge_behind, summary.branch.behind), BADGE_BEHIND)
    }
}

@Composable
private fun Part(text: String, color: Color) {
    Text(text, color = color, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
}

private val BADGE_CHANGED = Color(0xFFE8890C)
private val BADGE_AHEAD = Color(0xFF4A8FE7)
private val BADGE_BEHIND = Color(0xFFA371F7)
