package com.iaportafolio.argos.ui.claude

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.tmux.CodingAgent

/**
 * Icono de cada agente en pestañas y menús (port de `CodingAgentIcon` de `ArgosUI/ClaudeMascot.swift`):
 * la mascota pixel-art para Claude Code y un símbolo con su color para el resto. Decorativo: el
 * nombre del agente ya lo lee TalkBack en la pestaña o el menú.
 */
@Composable
fun CodingAgentIcon(agent: CodingAgent, modifier: Modifier = Modifier, size: Dp = 14.dp) {
    when (agent) {
        CodingAgent.CLAUDE -> ClaudeMascot(modifier, size)
        CodingAgent.CODEX -> Icon(painterResource(R.drawable.ic_agent_codex), contentDescription = null, tint = CODEX_TINT, modifier = modifier.size(size))
        CodingAgent.GROK -> Icon(painterResource(R.drawable.ic_agent_grok), contentDescription = null, tint = GROK_TINT, modifier = modifier.size(size))
    }
}

/** Mascota de Claude Code dibujada desde la misma cuadrícula que en Mac e iPhone (sin assets). */
@Composable
fun ClaudeMascot(modifier: Modifier = Modifier, height: Dp = 14.dp) {
    val columns = GRID.first().length
    val rows = GRID.size
    Canvas(modifier.height(height).width(height * columns / rows)) {
        val cell = minOf(size.width / columns, size.height / rows)
        GRID.forEachIndexed { row, line ->
            line.forEachIndexed { column, char ->
                val color = when (char) {
                    '#' -> MASCOT_BODY
                    'o' -> MASCOT_EYE
                    else -> return@forEachIndexed
                }
                // Un pelín más grande para que no se vean costuras entre píxeles.
                drawRect(color, Offset(column * cell - SEAM, row * cell - SEAM), Size(cell + 2 * SEAM, cell + 2 * SEAM))
            }
        }
    }
}

/** Cuadrícula: `#` cuerpo, `o` ojo, `.` vacío (la de `ClaudeMascot.grid`). */
private val GRID = listOf(
    "..#########..",
    "..##o###o##..",
    "..##o###o##..",
    "#############",
    "#############",
    "..#########..",
    "..#########..",
    "...#.#...#.#.",
    "...#.#...#.#.",
)

private const val SEAM = 0.15f
private val MASCOT_BODY = Color(0xFFD97757)
private val MASCOT_EYE = Color(0xFF1C1C1E)
private val CODEX_TINT = Color(0xFF0A84FF)
private val GROK_TINT = Color(0xFF999999)
