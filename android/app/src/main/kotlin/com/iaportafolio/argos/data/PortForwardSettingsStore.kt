package com.iaportafolio.argos.data

import android.content.Context
import android.os.Build
import android.provider.Settings
import androidx.core.content.edit
import com.iaportafolio.argos.core.ports.PortForwardDevice
import com.iaportafolio.argos.core.ports.PortForwardIdlePolicy
import java.util.UUID

/** Preferencias del reenvío de puertos en este teléfono (port de `PortForwardIdlePolicy` de Apple). */
interface PortForwardSettingsStore {
    /** Minutos sin conexiones tras los que se cierra un túnel (0 = nunca). */
    var idleMinutes: Int
}

/**
 * SharedPreferences. Al crearse aplica el límite y la identidad del teléfono (id estable y nombre)
 * a `core`, donde los leen el vigilante de túneles y el archivo de la skill de Claude.
 */
class SharedPreferencesPortForwardSettings(context: Context) : PortForwardSettingsStore {
    private val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    init {
        PortForwardIdlePolicy.limitMinutes = prefs.getInt(KEY_IDLE, PortForwardIdlePolicy.DEFAULT_MINUTES)
        PortForwardDevice.id = prefs.getString(KEY_DEVICE_ID, null)
            ?: UUID.randomUUID().toString().also { id -> prefs.edit { putString(KEY_DEVICE_ID, id) } }
        PortForwardDevice.name = deviceName(context)
    }

    override var idleMinutes: Int
        get() = PortForwardIdlePolicy.limitMinutes
        set(value) {
            PortForwardIdlePolicy.limitMinutes = value
            prefs.edit { putInt(KEY_IDLE, PortForwardIdlePolicy.limitMinutes) }
        }

    private companion object {
        const val FILE = "port_forwarding"
        const val KEY_IDLE = "idle_minutes"
        const val KEY_DEVICE_ID = "device_id"

        /** Nombre del dispositivo en Ajustes; si no lo hay, el modelo («Pixel 8»). */
        fun deviceName(context: Context): String =
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
                ?.takeIf { it.isNotBlank() }
                ?: Build.MODEL
    }
}
