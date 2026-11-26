package com.iaportafolio.argos.ui.claude

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.usage.ClaudeLimitLabel
import com.iaportafolio.argos.core.usage.ClaudeLimitReset
import com.iaportafolio.argos.core.usage.ClaudeLimitResetDay
import com.iaportafolio.argos.core.usage.ClaudeLimitWindow
import com.iaportafolio.argos.core.usage.ClaudeLimitsLevel
import com.iaportafolio.argos.core.usage.ClaudeLimitsStatus
import com.iaportafolio.argos.ui.monitor.WARNING_DARK
import com.iaportafolio.argos.ui.monitor.WARNING_LIGHT
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** Hora actual que se refresca cada minuto (los porcentajes caen a 0 al reiniciarse la ventana). */
@Composable
fun rememberMinuteClock(): State<Instant> = produceState(Instant.now()) {
    while (true) {
        delay(MINUTE_MILLIS)
        value = Instant.now()
    }
}

private const val MINUTE_MILLIS = 60_000L

/** Nombre de la ventana («Ventana de 5 h», «Semana», «Semana (Opus)»…). */
@Composable
fun ClaudeLimitWindow.labelText(): String = when (val label = label) {
    ClaudeLimitLabel.FiveHour -> stringResource(R.string.claude_limits_five_hour)
    ClaudeLimitLabel.SevenDay -> stringResource(R.string.claude_limits_seven_day)
    is ClaudeLimitLabel.SevenDayScoped -> stringResource(R.string.claude_limits_seven_day_scoped, label.scope)
    is ClaudeLimitLabel.Other -> label.name
}

/** «a las 18:30» hoy, «mañana a las 9:00» o «el lun 9 a las 9:00» más adelante. */
@Composable
fun resetText(reset: Instant, now: Instant): String {
    val zone = ZoneId.systemDefault()
    // El idioma se lee de la configuración (observable): si cambia, se recompone.
    val locale: Locale = LocalConfiguration.current.locales[0]
    val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).withZone(zone).format(reset)
    return when (ClaudeLimitReset.day(reset, now, zone)) {
        ClaudeLimitResetDay.TODAY -> stringResource(R.string.claude_limits_reset_today, time)
        ClaudeLimitResetDay.TOMORROW -> stringResource(R.string.claude_limits_reset_tomorrow, time)
        ClaudeLimitResetDay.LATER -> {
            val day = DateTimeFormatter.ofPattern("EEE d", locale).withZone(zone).format(reset)
            stringResource(R.string.claude_limits_reset_later, day, time)
        }
    }
}

@Composable
fun ClaudeLimitsStatus.titleText(): String = when (level) {
    ClaudeLimitsLevel.NORMAL -> stringResource(R.string.claude_limits_title_normal)
    ClaudeLimitsLevel.HIGH -> stringResource(R.string.claude_limits_title_high)
    ClaudeLimitsLevel.CRITICAL -> stringResource(R.string.claude_limits_title_critical)
}

/** «Llevas el 87 % de «Ventana de 5 h»; se reinicia a las 18:30.» */
@Composable
fun ClaudeLimitsStatus.messageText(now: Instant): String {
    val window = worst.labelText()
    val reset = worst.resetsAt?.takeIf { it.isAfter(now) }
        ?: return stringResource(R.string.claude_limits_message, worstPercent, window)
    return stringResource(R.string.claude_limits_message_reset, worstPercent, window, resetText(reset, now))
}

/** Línea compacta para la lista del servidor: «Ventana de 5 h 42 % · Semana 8 %». */
@Composable
fun ClaudeLimitsCompactRow(status: ClaudeLimitsStatus, modifier: Modifier = Modifier) {
    val now by rememberMinuteClock()
    val parts = status.reading.windows.map { window ->
        stringResource(R.string.claude_limits_window_percent, window.labelText(), window.displayPercent(now))
    }
    Row(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            painterResource(R.drawable.ic_gauge),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(16.dp),
        )
        Text(
            parts.joinToString(" · "),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Aviso «te acercas al límite de Claude» (alto en ámbar, crítico con el color de error), como el de memoria. */
@Composable
fun ClaudeLimitsBanner(status: ClaudeLimitsStatus, modifier: Modifier = Modifier) {
    val now by rememberMinuteClock()
    val (container, content) = when (status.level) {
        ClaudeLimitsLevel.CRITICAL -> MaterialTheme.colorScheme.errorContainer to MaterialTheme.colorScheme.onErrorContainer
        ClaudeLimitsLevel.HIGH, ClaudeLimitsLevel.NORMAL ->
            if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) WARNING_DARK else WARNING_LIGHT
    }
    Row(
        modifier
            .fillMaxWidth()
            .background(container)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(painterResource(R.drawable.ic_gauge), contentDescription = null, tint = content)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(status.titleText(), style = MaterialTheme.typography.titleSmall, color = content)
            Text(status.messageText(now), style = MaterialTheme.typography.bodySmall, color = content)
        }
    }
}

/** Línea de la lista: el aviso al acercarse al límite o, si no, la línea compacta. */
@Composable
fun ClaudeLimitsListRow(status: ClaudeLimitsStatus) {
    if (status.level > ClaudeLimitsLevel.NORMAL) ClaudeLimitsBanner(status) else ClaudeLimitsCompactRow(status)
}

/** Una barra por ventana (5 h, semana…) con su porcentaje y cuándo se reinicia. */
@Composable
fun ClaudeLimitsMeters(status: ClaudeLimitsStatus, modifier: Modifier = Modifier) {
    val now by rememberMinuteClock()
    Column(modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        status.reading.windows.forEach { window -> ClaudeLimitMeterRow(window, now) }
        val updated = DateUtils.getRelativeTimeSpanString(
            status.reading.capturedAt.toEpochMilli(),
            now.toEpochMilli(),
            DateUtils.MINUTE_IN_MILLIS,
        ).toString()
        Text(
            stringResource(R.string.claude_limits_updated, updated),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.outline,
        )
    }
}

@Composable
private fun ClaudeLimitMeterRow(window: ClaudeLimitWindow, now: Instant) {
    val percent = window.effectivePercent(now)
    val tint: Color = when {
        percent >= ClaudeLimitsStatus.CRITICAL_FROM -> MaterialTheme.colorScheme.error
        percent >= ClaudeLimitsStatus.HIGH_FROM -> WARNING_AMBER
        else -> MaterialTheme.colorScheme.primary
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(window.labelText(), style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.weight(1f))
            Text(
                stringResource(R.string.claude_limits_percent, window.displayPercent(now)),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        LinearProgressIndicator(progress = { (percent / 100).toFloat() }, color = tint, modifier = Modifier.fillMaxWidth())
        window.resetsAt?.takeIf { it.isAfter(now) }?.let { reset ->
            Text(
                stringResource(R.string.claude_limits_resets, resetText(reset, now)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Ámbar de las barras al 85 % (legible sobre claro y oscuro). */
private val WARNING_AMBER = Color(0xFFF57C00)
