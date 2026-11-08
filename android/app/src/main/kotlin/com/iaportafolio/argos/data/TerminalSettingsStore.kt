package com.iaportafolio.argos.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Preferencias del terminal (equivalen a `@AppStorage("terminal.fontSize")` de iOS). */
data class TerminalSettings(
    val fontSizeSp: Int = DEFAULT_FONT_SIZE_SP,
    /** Mantener la pantalla encendida mientras el terminal está a la vista. */
    val keepScreenOn: Boolean = true,
) {
    companion object {
        const val DEFAULT_FONT_SIZE_SP = 12
        const val MIN_FONT_SIZE_SP = 6
        const val MAX_FONT_SIZE_SP = 32

        fun clampFontSize(sp: Int): Int = sp.coerceIn(MIN_FONT_SIZE_SP, MAX_FONT_SIZE_SP)
    }
}

interface TerminalSettingsStore {
    val settings: StateFlow<TerminalSettings>
    fun setFontSize(sp: Int)
    fun setKeepScreenOn(enabled: Boolean)
}

/** [TerminalSettingsStore] sobre `SharedPreferences` (no son secretos). */
class SharedPreferencesTerminalSettings(context: Context) : TerminalSettingsStore {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private val state = MutableStateFlow(
        TerminalSettings(
            fontSizeSp = TerminalSettings.clampFontSize(prefs.getInt(KEY_FONT_SIZE, TerminalSettings.DEFAULT_FONT_SIZE_SP)),
            keepScreenOn = prefs.getBoolean(KEY_KEEP_SCREEN_ON, true),
        ),
    )
    override val settings: StateFlow<TerminalSettings> = state.asStateFlow()

    override fun setFontSize(sp: Int) {
        val clamped = TerminalSettings.clampFontSize(sp)
        if (clamped == state.value.fontSizeSp) return
        state.update { it.copy(fontSizeSp = clamped) }
        prefs.edit { putInt(KEY_FONT_SIZE, clamped) }
    }

    override fun setKeepScreenOn(enabled: Boolean) {
        state.update { it.copy(keepScreenOn = enabled) }
        prefs.edit { putBoolean(KEY_KEEP_SCREEN_ON, enabled) }
    }

    private companion object {
        const val FILE = "terminal"
        const val KEY_FONT_SIZE = "terminal.fontSize"
        const val KEY_KEEP_SCREEN_ON = "terminal.keepScreenOn"
    }
}
