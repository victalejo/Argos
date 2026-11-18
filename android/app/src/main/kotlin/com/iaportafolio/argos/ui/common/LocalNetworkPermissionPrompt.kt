package com.iaportafolio.argos.ui.common

import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.net.toUri
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.LocalNetworkPermission
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.LocalNetworkGate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Pide el permiso de red local (Android 17, «Dispositivos cercanos») al abrir un servidor de la
 * Wi-Fi: IP privada, `.local` o un nombre que resuelve a la LAN. Sin él la conexión se cortaría por
 * «timeout». Se pide una vez por pantalla; si se deniega, un diálogo explica el motivo y lleva a los
 * ajustes del sistema. [onGranted] reintenta la carga de la pantalla.
 */
@Composable
internal fun LocalNetworkPermissionPrompt(gate: LocalNetworkGate, host: String?, onGranted: () -> Unit) {
    val permission = LocalNetworkPermission.name ?: return
    if (host == null) return
    val context = LocalContext.current
    val currentOnGranted by rememberUpdatedState(onGranted)
    var asked by rememberSaveable(host) { mutableStateOf(false) }
    var explainDenied by rememberSaveable(host) { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        ArgosLog.info(ArgosLog.TAG_SSH, "Permiso de red local: $granted")
        if (granted) currentOnGranted() else explainDenied = true
    }
    LaunchedEffect(host) {
        if (asked) return@LaunchedEffect
        // Puede resolver el nombre (DNS): fuera del hilo principal.
        if (withContext(Dispatchers.IO) { gate.blocks(host) }) {
            asked = true
            launcher.launch(permission)
        }
    }
    // Al volver de los ajustes del sistema, ya concedido: se cierra el aviso y se reintenta.
    LifecycleResumeEffect(explainDenied) {
        if (explainDenied && LocalNetworkPermission.isGranted(context)) {
            explainDenied = false
            currentOnGranted()
        }
        onPauseOrDispose { }
    }
    if (explainDenied) {
        AlertDialog(
            onDismissRequest = { explainDenied = false },
            title = { Text(stringResource(R.string.local_network_title)) },
            text = { Text(stringResource(R.string.local_network_denied, host)) },
            confirmButton = {
                TextButton(onClick = { openAppSettings(context) }) { Text(stringResource(R.string.background_open_system_settings)) }
            },
            dismissButton = {
                TextButton(onClick = { explainDenied = false }) { Text(stringResource(R.string.local_network_not_now)) }
            },
        )
    }
}

/** Ajustes de Argos en el sistema (Permisos → Dispositivos cercanos). */
internal fun openAppSettings(context: Context) {
    context.startActivity(
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri()),
    )
}
