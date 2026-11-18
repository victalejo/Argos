package com.iaportafolio.argos.background

import com.iaportafolio.argos.data.ArgosLog
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.time.Duration
import java.time.Instant

/** Quién lanzó una comprobación de avisos. */
enum class CheckTrigger {
    /** WorkManager (cada 15 min como mínimo, cuando el sistema lo deja correr). */
    BACKGROUND,

    /** La app a la vista (al volver a primer plano y cada minuto). */
    FOREGROUND,

    /** «Comprobar ahora» del diagnóstico. */
    MANUAL,
}

/** Cómo acabó la revisión de un servidor. */
enum class ServerCheckResult {
    CHECKED,

    /** Error de conexión o del script (servidor caído, credenciales…). */
    FAILED,

    /** No respondió dentro del plazo. */
    NO_RESPONSE,

    /** Servidor de la Wi-Fi sin el permiso de red local (Android 17): no se intenta. */
    LOCAL_NETWORK_BLOCKED,

    /** Sin huella guardada: en segundo plano nunca se confía en una nueva. */
    UNTRUSTED,
}

/** Última comprobación, para la pantalla de diagnóstico. Sin nombres ni contenido: solo cuentas. */
data class CheckRecord(
    val at: Instant,
    val trigger: CheckTrigger,
    val outcome: AgentCheckOutcome,
    val results: Map<ServerCheckResult, Int> = emptyMap(),
) {
    fun count(result: ServerCheckResult): Int = results[result] ?: 0
}

/** Persiste la última [CheckRecord] (sobrevive a la muerte del proceso, como el worker). */
class BackgroundDiagnosticsStore(private val backend: AgentWatchBackend) {

    @Serializable
    private data class Stored(
        val at: Long,
        val trigger: String,
        val outcome: String,
        val results: Map<String, Int> = emptyMap(),
    )

    private val state = MutableStateFlow(load())

    val lastCheck: StateFlow<CheckRecord?> = state.asStateFlow()

    fun record(record: CheckRecord) {
        state.value = record
        val stored = Stored(
            at = record.at.toEpochMilli(),
            trigger = record.trigger.name,
            outcome = record.outcome.name,
            results = record.results.mapKeys { it.key.name },
        )
        backend.write(KEY_LAST_CHECK, JSON.encodeToString(Stored.serializer(), stored))
    }

    private fun load(): CheckRecord? {
        val text = backend.read(KEY_LAST_CHECK) ?: return null
        return try {
            val stored = JSON.decodeFromString(Stored.serializer(), text)
            CheckRecord(
                at = Instant.ofEpochMilli(stored.at),
                trigger = CheckTrigger.entries.firstOrNull { it.name == stored.trigger } ?: CheckTrigger.BACKGROUND,
                outcome = AgentCheckOutcome.entries.firstOrNull { it.name == stored.outcome } ?: AgentCheckOutcome.CHECKED,
                results = stored.results.mapNotNull { (key, value) ->
                    ServerCheckResult.entries.firstOrNull { it.name == key }?.let { it to value }
                }.toMap(),
            )
        } catch (error: SerializationException) {
            ArgosLog.warn(ArgosLog.TAG_STORE, "$KEY_LAST_CHECK no es válido; se ignora (${error::class.java.simpleName})")
            null
        } catch (error: IllegalArgumentException) {
            ArgosLog.warn(ArgosLog.TAG_STORE, "$KEY_LAST_CHECK no es válido; se ignora (${error::class.java.simpleName})")
            null
        }
    }

    private companion object {
        const val KEY_LAST_CHECK = "diagnostics.lastCheck"
        val JSON = Json { ignoreUnknownKeys = true }
    }
}

/** Bucket de App Standby (`UsageStatsManager.getAppStandbyBucket`): cuánto deja correr el sistema. */
enum class StandbyBucket {
    ACTIVE, WORKING_SET, FREQUENT, RARE, RESTRICTED, UNKNOWN;

    /** Con RARE o RESTRICTED los trabajos periódicos se retrasan horas (o casi no corren). */
    val delaysWork: Boolean get() = this == RARE || this == RESTRICTED

    companion object {
        /** Valores de `UsageStatsManager.STANDBY_BUCKET_*` (estables desde Android 9). */
        fun fromSystem(value: Int): StandbyBucket = when (value) {
            10 -> ACTIVE
            20 -> WORKING_SET
            30 -> FREQUENT
            40 -> RARE
            45 -> RESTRICTED
            else -> UNKNOWN
        }
    }
}

/** Lo que puede retrasar o impedir los avisos, de más grave a menos. */
enum class BackgroundWarning {
    NOTIFICATIONS_BLOCKED,
    NOTIFICATIONS_DISABLED,
    LOCAL_NETWORK_BLOCKED,
    RESTRICTED_BUCKET,
    STALE_CHECK,
    BATTERY_OPTIMIZED,
}

/** Datos del sistema y de Argos que ve la pantalla de diagnóstico. */
data class BackgroundHealth(
    val lastCheck: CheckRecord?,
    val bucket: StandbyBucket,
    val batteryOptimized: Boolean,
    val notificationsAllowed: Boolean,
    val notificationsEnabled: Boolean,
    val hasWatchedWork: Boolean,
) {
    /** Avisos a mostrar ahora (lógica pura: la UI solo los pinta). */
    fun warnings(now: Instant): List<BackgroundWarning> = buildList {
        if (!notificationsAllowed) add(BackgroundWarning.NOTIFICATIONS_BLOCKED)
        if (!notificationsEnabled) add(BackgroundWarning.NOTIFICATIONS_DISABLED)
        if ((lastCheck?.count(ServerCheckResult.LOCAL_NETWORK_BLOCKED) ?: 0) > 0) add(BackgroundWarning.LOCAL_NETWORK_BLOCKED)
        if (bucket.delaysWork) add(BackgroundWarning.RESTRICTED_BUCKET)
        val last = lastCheck?.at
        if (hasWatchedWork && notificationsEnabled && (last == null || Duration.between(last, now) > STALE_AFTER)) {
            add(BackgroundWarning.STALE_CHECK)
        }
        if (batteryOptimized && hasWatchedWork) add(BackgroundWarning.BATTERY_OPTIMIZED)
    }

    companion object {
        /** Más de una hora sin comprobar con algo vigilado: el sistema está frenando el trabajo. */
        val STALE_AFTER: Duration = Duration.ofHours(1)
    }
}
