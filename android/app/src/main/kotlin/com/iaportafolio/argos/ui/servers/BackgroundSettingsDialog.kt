package com.iaportafolio.argos.ui.servers

import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.agentNotificationsAllowed

/** Avisos de agentes y terminal en segundo plano. */
@Composable
internal fun BackgroundSettingsDialog(
    agentNotificationsEnabled: Boolean,
    keepTerminalAlive: Boolean,
    onAgentNotificationsChange: (Boolean) -> Unit,
    onKeepTerminalAliveChange: (Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    // Al volver de los ajustes del sistema el bloqueo puede haber cambiado.
    var allowed by remember { mutableStateOf(agentNotificationsAllowed(context)) }
    LifecycleResumeEffect(Unit) {
        allowed = agentNotificationsAllowed(context)
        onPauseOrDispose { }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.background_settings_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                SettingSwitch(
                    title = stringResource(R.string.background_agents_title),
                    detail = stringResource(R.string.background_agents_detail),
                    checked = agentNotificationsEnabled,
                    onChange = onAgentNotificationsChange,
                )
                if (agentNotificationsEnabled && !allowed) {
                    Column {
                        Text(
                            stringResource(R.string.background_notifications_blocked),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                        TextButton(onClick = { openNotificationSettings(context) }) {
                            Text(stringResource(R.string.background_open_system_settings))
                        }
                    }
                }
                SettingSwitch(
                    title = stringResource(R.string.background_keep_terminal_title),
                    detail = stringResource(R.string.background_keep_terminal_detail),
                    checked = keepTerminalAlive,
                    onChange = onKeepTerminalAliveChange,
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_close)) } },
    )
}

@Composable
private fun SettingSwitch(title: String, detail: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().toggleable(value = checked, role = Role.Switch, onValueChange = onChange),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = checked, onCheckedChange = null)
    }
}

private fun openNotificationSettings(context: Context) {
    context.startActivity(
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
    )
}
