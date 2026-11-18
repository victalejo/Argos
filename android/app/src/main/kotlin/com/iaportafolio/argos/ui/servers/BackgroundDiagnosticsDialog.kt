package com.iaportafolio.argos.ui.servers

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.AgentCheckOutcome
import com.iaportafolio.argos.background.BackgroundHealth
import com.iaportafolio.argos.background.BackgroundWarning
import com.iaportafolio.argos.background.CheckRecord
import com.iaportafolio.argos.background.CheckTrigger
import com.iaportafolio.argos.background.ServerCheckResult
import com.iaportafolio.argos.background.StandbyBucket
import com.iaportafolio.argos.background.SystemBackgroundState
import com.iaportafolio.argos.background.agentNotificationsAllowed
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.ui.common.openAppSettings
import java.time.Instant

/** Lo que Argos sabe de sus avisos (el resto lo pregunta el diálogo al sistema). */
data class DiagnosticsInput(
    val lastCheck: CheckRecord?,
    val ciWatchCount: Int,
    val notificationsEnabled: Boolean,
    val hasWatchedWork: Boolean,
    val isChecking: Boolean,
)

/**
 * Por qué un aviso puede tardar: última comprobación y su resultado, bucket de App Standby y
 * optimización de batería, con acceso a los ajustes del sistema. Se relee al volver de ellos.
 */
@Composable
internal fun BackgroundDiagnosticsDialog(input: DiagnosticsInput, onCheckNow: () -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var system by remember { mutableStateOf(readSystem(context)) }
    LifecycleResumeEffect(Unit) {
        system = readSystem(context)
        onPauseOrDispose { }
    }
    val health = BackgroundHealth(
        lastCheck = input.lastCheck,
        bucket = system.bucket,
        batteryOptimized = system.batteryOptimized,
        notificationsAllowed = system.notificationsAllowed,
        notificationsEnabled = input.notificationsEnabled,
        hasWatchedWork = input.hasWatchedWork,
    )
    val now = Instant.now()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.diagnostics_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Section(stringResource(R.string.diagnostics_last_check), lastCheckText(input.lastCheck, now))
                Section(stringResource(R.string.diagnostics_bucket), bucketText(system.bucket))
                Section(
                    stringResource(R.string.diagnostics_battery),
                    stringResource(if (system.batteryOptimized) R.string.diagnostics_battery_optimized else R.string.diagnostics_battery_unrestricted),
                )
                Section(stringResource(R.string.diagnostics_ci), stringResource(R.string.diagnostics_ci_count, input.ciWatchCount))
                health.warnings(now).forEach { warning ->
                    Text(warningText(warning), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
                TextButton(onClick = { openBatterySettings(context) }) { Text(stringResource(R.string.diagnostics_open_battery)) }
                TextButton(onClick = { openAppSettings(context) }) { Text(stringResource(R.string.diagnostics_open_app)) }
            }
        },
        confirmButton = {
            TextButton(onClick = onCheckNow, enabled = !input.isChecking) {
                Text(stringResource(if (input.isChecking) R.string.diagnostics_checking else R.string.diagnostics_check_now))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_close)) } },
    )
}

private data class SystemState(val bucket: StandbyBucket, val batteryOptimized: Boolean, val notificationsAllowed: Boolean)

private fun readSystem(context: Context) = SystemState(
    bucket = SystemBackgroundState.standbyBucket(context),
    batteryOptimized = SystemBackgroundState.isBatteryOptimized(context),
    notificationsAllowed = agentNotificationsAllowed(context),
)

@Composable
private fun Section(title: String, body: String) {
    Column {
        Text(title, style = MaterialTheme.typography.titleSmall)
        Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun lastCheckText(record: CheckRecord?, now: Instant): String {
    if (record == null) return stringResource(R.string.diagnostics_never)
    val whenText = DateUtils.getRelativeTimeSpanString(record.at.toEpochMilli(), now.toEpochMilli(), DateUtils.MINUTE_IN_MILLIS).toString()
    val trigger = stringResource(
        when (record.trigger) {
            CheckTrigger.BACKGROUND -> R.string.diagnostics_trigger_background
            CheckTrigger.FOREGROUND -> R.string.diagnostics_trigger_foreground
            CheckTrigger.MANUAL -> R.string.diagnostics_trigger_manual
        },
    )
    val result = when (record.outcome) {
        AgentCheckOutcome.DISABLED -> stringResource(R.string.diagnostics_outcome_disabled)
        AgentCheckOutcome.BLOCKED -> stringResource(R.string.diagnostics_outcome_blocked)
        AgentCheckOutcome.BUSY -> stringResource(R.string.diagnostics_outcome_busy)
        AgentCheckOutcome.CHECKED -> stringResource(
            R.string.diagnostics_outcome_checked,
            record.count(ServerCheckResult.CHECKED),
            record.count(ServerCheckResult.FAILED) + record.count(ServerCheckResult.NO_RESPONSE),
            record.count(ServerCheckResult.LOCAL_NETWORK_BLOCKED) + record.count(ServerCheckResult.UNTRUSTED),
        )
    }
    return stringResource(R.string.diagnostics_last_check_value, whenText, trigger, result)
}

@Composable
private fun bucketText(bucket: StandbyBucket): String = stringResource(
    when (bucket) {
        StandbyBucket.ACTIVE -> R.string.diagnostics_bucket_active
        StandbyBucket.WORKING_SET -> R.string.diagnostics_bucket_working_set
        StandbyBucket.FREQUENT -> R.string.diagnostics_bucket_frequent
        StandbyBucket.RARE -> R.string.diagnostics_bucket_rare
        StandbyBucket.RESTRICTED -> R.string.diagnostics_bucket_restricted
        StandbyBucket.UNKNOWN -> R.string.diagnostics_bucket_unknown
    },
)

@Composable
private fun warningText(warning: BackgroundWarning): String = stringResource(
    when (warning) {
        BackgroundWarning.NOTIFICATIONS_BLOCKED -> R.string.background_notifications_blocked
        BackgroundWarning.NOTIFICATIONS_DISABLED -> R.string.diagnostics_warning_disabled
        BackgroundWarning.LOCAL_NETWORK_BLOCKED -> R.string.diagnostics_warning_local_network
        BackgroundWarning.RESTRICTED_BUCKET -> R.string.diagnostics_warning_bucket
        BackgroundWarning.STALE_CHECK -> R.string.diagnostics_warning_stale
        BackgroundWarning.BATTERY_OPTIMIZED -> R.string.diagnostics_warning_battery
    },
)

/**
 * Lista de «Optimización de batería» del sistema. No se usa `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
 * (Google Play lo restringe): el usuario elige Argos en la lista. Algunos fabricantes no la tienen.
 */
private fun openBatterySettings(context: Context) {
    try {
        context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    } catch (error: ActivityNotFoundException) {
        ArgosLog.warn(ArgosLog.TAG_UI, "Sin ajustes de batería en este teléfono (${error::class.java.simpleName})")
        openAppSettings(context)
    }
}
