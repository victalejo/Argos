package com.iaportafolio.argos.ui.terminal

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.iaportafolio.argos.R
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Orden de la fila (desplazable en horizontal si no cabe). */
private val ROW_KEYS = listOf(
    ExtraKey.ESC, ExtraKey.TAB, ExtraKey.CTRL, ExtraKey.ALT,
    ExtraKey.LEFT, ExtraKey.UP, ExtraKey.DOWN, ExtraKey.RIGHT,
    ExtraKey.PIPE, ExtraKey.TILDE, ExtraKey.SLASH, ExtraKey.DASH,
    ExtraKey.TMUX_PREFIX, ExtraKey.HOME, ExtraKey.END, ExtraKey.PAGE_UP, ExtraKey.PAGE_DOWN,
)

private const val REPEAT_START_DELAY_MS = 400L
private const val REPEAT_INTERVAL_MS = 50L

/** Fila de teclas extra sobre el teclado (Esc, Tab, Ctrl/Alt pegajosos, flechas, prefijo tmux…). */
@Composable
fun ExtraKeysRow(modifiers: StickyModifiers, onKey: (ExtraKey) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(TerminalColors.Bar)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ROW_KEYS.forEach { key ->
            val latch = when (key) {
                ExtraKey.CTRL -> modifiers.ctrl
                ExtraKey.ALT -> modifiers.alt
                else -> null
            }
            ExtraKeyButton(key, latch, onKey)
        }
    }
}

@Composable
private fun ExtraKeyButton(key: ExtraKey, latch: ModifierLatch?, onKey: (ExtraKey) -> Unit) {
    val currentOnKey by rememberUpdatedState(onKey)
    val description = stringResource(key.descriptionRes())
    val state = latch?.let { stringResource(it.stateRes()) }
    val background = when (latch) {
        ModifierLatch.ONCE -> TerminalColors.KeyActive
        ModifierLatch.LOCKED -> TerminalColors.KeyLocked
        ModifierLatch.OFF, null -> TerminalColors.Key
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .height(40.dp)
            .widthIn(min = 44.dp)
            .background(background, RoundedCornerShape(6.dp))
            .then(if (latch == ModifierLatch.LOCKED) Modifier.border(1.dp, Color.White, RoundedCornerShape(6.dp)) else Modifier)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                role = Role.Button
                state?.let { stateDescription = it }
                onClick { currentOnKey(key); true }
            }
            .pointerInput(key) {
                coroutineScope {
                    val scope = this
                    awaitEachGesture {
                        awaitFirstDown()
                        currentOnKey(key)
                        // Mantener pulsada una flecha la repite, como en un teclado físico.
                        val repeater = if (key.repeats) {
                            scope.launch {
                                delay(REPEAT_START_DELAY_MS)
                                while (true) {
                                    currentOnKey(key)
                                    delay(REPEAT_INTERVAL_MS)
                                }
                            }
                        } else {
                            null
                        }
                        waitForUpOrCancellation()
                        repeater?.cancel()
                    }
                }
            }
            .padding(horizontal = 10.dp),
    ) {
        Text(
            stringResource(key.labelRes()),
            color = Color.White,
            fontFamily = FontFamily.Monospace,
            fontWeight = if (latch != null && latch != ModifierLatch.OFF) FontWeight.Bold else FontWeight.Normal,
            fontSize = 14.sp,
        )
    }
}

@StringRes
private fun ExtraKey.labelRes(): Int = when (this) {
    ExtraKey.ESC -> R.string.key_esc
    ExtraKey.TAB -> R.string.key_tab
    ExtraKey.CTRL -> R.string.key_ctrl
    ExtraKey.ALT -> R.string.key_alt
    ExtraKey.LEFT -> R.string.key_left
    ExtraKey.UP -> R.string.key_up
    ExtraKey.DOWN -> R.string.key_down
    ExtraKey.RIGHT -> R.string.key_right
    ExtraKey.PIPE -> R.string.key_pipe
    ExtraKey.TILDE -> R.string.key_tilde
    ExtraKey.SLASH -> R.string.key_slash
    ExtraKey.DASH -> R.string.key_dash
    ExtraKey.TMUX_PREFIX -> R.string.key_tmux_prefix
    ExtraKey.HOME -> R.string.key_home
    ExtraKey.END -> R.string.key_end
    ExtraKey.PAGE_UP -> R.string.key_page_up
    ExtraKey.PAGE_DOWN -> R.string.key_page_down
}

@StringRes
private fun ExtraKey.descriptionRes(): Int = when (this) {
    ExtraKey.ESC -> R.string.key_esc_description
    ExtraKey.TAB -> R.string.key_tab_description
    ExtraKey.CTRL -> R.string.key_ctrl_description
    ExtraKey.ALT -> R.string.key_alt_description
    ExtraKey.LEFT -> R.string.key_left_description
    ExtraKey.UP -> R.string.key_up_description
    ExtraKey.DOWN -> R.string.key_down_description
    ExtraKey.RIGHT -> R.string.key_right_description
    ExtraKey.PIPE -> R.string.key_pipe_description
    ExtraKey.TILDE -> R.string.key_tilde_description
    ExtraKey.SLASH -> R.string.key_slash_description
    ExtraKey.DASH -> R.string.key_dash_description
    ExtraKey.TMUX_PREFIX -> R.string.key_tmux_prefix_description
    ExtraKey.HOME -> R.string.key_home_description
    ExtraKey.END -> R.string.key_end_description
    ExtraKey.PAGE_UP -> R.string.key_page_up_description
    ExtraKey.PAGE_DOWN -> R.string.key_page_down_description
}

@StringRes
private fun ModifierLatch.stateRes(): Int = when (this) {
    ModifierLatch.OFF -> R.string.key_state_off
    ModifierLatch.ONCE -> R.string.key_state_once
    ModifierLatch.LOCKED -> R.string.key_state_locked
}

/** Colores fijos del terminal (oscuro, como en iOS), independientes del tema del sistema. */
internal object TerminalColors {
    val Background = Color(0xFF000000)
    val Bar = Color(0xFF1C1C1E)
    val Key = Color(0xFF3A3A3C)
    val KeyActive = Color(0xFF5E5CE6)
    val KeyLocked = Color(0xFF3634A3)
    val OnBar = Color(0xFFEBEBF0)
    val OnBarSecondary = Color(0xFF98989F)
}
