package com.iaportafolio.argos.ui.agents

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.iaportafolio.argos.background.AgentNotifier
import com.iaportafolio.argos.data.ArgosLog

/**
 * Al abrir un agente o un terminal pide `POST_NOTIFICATIONS` (Android 13+) una sola vez. Si se
 * rechaza no se insiste: los ajustes de Argos muestran el bloqueo y enlazan con los del sistema.
 *
 * Con [forTerminal] se pide aunque los avisos de agentes estén desactivados: sin el permiso, la
 * notificación fija del terminal en segundo plano no se ve y los avisos de CI se descartan.
 */
@Composable
internal fun RequestAgentNotificationPermission(notifier: AgentNotifier, forTerminal: Boolean = false) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        ArgosLog.info(ArgosLog.TAG_AGENT, "Permiso de notificaciones: $granted")
    }
    LaunchedEffect(Unit) {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (notifier.claimPermissionRequest(granted, forTerminal)) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
