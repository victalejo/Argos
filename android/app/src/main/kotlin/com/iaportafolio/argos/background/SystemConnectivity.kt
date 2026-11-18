package com.iaportafolio.argos.background

import android.Manifest
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.LocalNetworkGate

/** Permiso de red local de Android 17 (`ACCESS_LOCAL_NETWORK`, grupo «Dispositivos cercanos»). */
object LocalNetworkPermission {
    /** Solo aplica en Android 17+ (y la app tiene target 37). */
    val isRequired: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.CINNAMON_BUN

    /** Nombre del permiso, o `null` si este Android no lo tiene. */
    val name: String?
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.CINNAMON_BUN) Manifest.permission.ACCESS_LOCAL_NETWORK else null

    fun isGranted(context: Context): Boolean {
        val permission = name ?: return true
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    /** Puerta real (se consulta en cada conexión: el usuario puede concederlo o retirarlo). */
    fun gate(context: Context): LocalNetworkGate {
        val appContext = context.applicationContext
        return LocalNetworkGate({ isRequired }, { isGranted(appContext) }, LocalNetworkGate::systemResolver)
    }
}

/**
 * Vigila la red por defecto: al cambiar (Wi-Fi → datos, otra Wi-Fi) o volver tras perderla, las
 * conexiones abiertas pueden haber muerto sin avisar: se sondean con plazo corto y las que no
 * responden se sueltan para que la pantalla siguiente (y los terminales) reconecten al momento.
 */
class SystemNetworkMonitor(context: Context, private val onNetworkChanged: () -> Unit) {
    private val manager = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val tracker = NetworkChangeTracker()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (tracker.onAvailable(network.networkHandle)) {
                ArgosLog.info(ArgosLog.TAG_SSH, "Cambió la red: se comprueban las conexiones abiertas")
                onNetworkChanged()
            }
        }

        override fun onLost(network: Network) = tracker.onLost(network.networkHandle)
    }

    fun start() {
        try {
            manager?.registerDefaultNetworkCallback(callback)
        } catch (error: RuntimeException) {
            // Límite de callbacks por app o un fabricante raro: sin esto, solo se pierde la mejora.
            ArgosLog.warn(ArgosLog.TAG_SSH, "No se pudo vigilar la red (${error::class.java.simpleName})")
        }
    }
}

/** Lo que dice el sistema sobre cuánto deja correr a Argos en segundo plano. */
object SystemBackgroundState {
    fun standbyBucket(context: Context): StandbyBucket {
        val manager = context.getSystemService(UsageStatsManager::class.java) ?: return StandbyBucket.UNKNOWN
        return StandbyBucket.fromSystem(manager.appStandbyBucket)
    }

    /** `true` = Android puede frenar el trabajo de Argos para ahorrar batería (lo normal). */
    fun isBatteryOptimized(context: Context): Boolean {
        val manager = context.getSystemService(PowerManager::class.java) ?: return true
        return !manager.isIgnoringBatteryOptimizations(context.packageName)
    }
}
