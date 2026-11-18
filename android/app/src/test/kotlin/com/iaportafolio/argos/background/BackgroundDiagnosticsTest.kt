package com.iaportafolio.argos.background

import com.iaportafolio.argos.testing.InMemoryAgentWatchBackend
import org.junit.jupiter.api.Test
import java.time.Duration
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BackgroundDiagnosticsTest {

    private val now = Instant.parse("2026-11-18T12:00:00Z")

    @Test
    fun `la última comprobación sobrevive a un proceso nuevo`() {
        val backend = InMemoryAgentWatchBackend()
        val record = CheckRecord(
            at = now,
            trigger = CheckTrigger.BACKGROUND,
            outcome = AgentCheckOutcome.CHECKED,
            results = mapOf(ServerCheckResult.CHECKED to 2, ServerCheckResult.LOCAL_NETWORK_BLOCKED to 1),
        )
        BackgroundDiagnosticsStore(backend).record(record)

        assertEquals(record, BackgroundDiagnosticsStore(backend).lastCheck.value)
    }

    @Test
    fun `un registro dañado o de una versión futura no rompe nada`() {
        assertNull(BackgroundDiagnosticsStore(InMemoryAgentWatchBackend(mapOf("diagnostics.lastCheck" to "{roto"))).lastCheck.value)
        val future = """{"at":1,"trigger":"OTRO","outcome":"NUEVO","results":{"RARO":3,"CHECKED":1},"extra":true}"""
        val loaded = BackgroundDiagnosticsStore(InMemoryAgentWatchBackend(mapOf("diagnostics.lastCheck" to future))).lastCheck.value
        assertEquals(CheckTrigger.BACKGROUND, loaded?.trigger)
        assertEquals(mapOf(ServerCheckResult.CHECKED to 1), loaded?.results)
    }

    @Test
    fun `buckets del sistema`() {
        assertEquals(StandbyBucket.ACTIVE, StandbyBucket.fromSystem(10))
        assertEquals(StandbyBucket.WORKING_SET, StandbyBucket.fromSystem(20))
        assertEquals(StandbyBucket.FREQUENT, StandbyBucket.fromSystem(30))
        assertEquals(StandbyBucket.RARE, StandbyBucket.fromSystem(40))
        assertEquals(StandbyBucket.RESTRICTED, StandbyBucket.fromSystem(45))
        assertEquals(StandbyBucket.UNKNOWN, StandbyBucket.fromSystem(5))
        assertTrue(StandbyBucket.RARE.delaysWork && StandbyBucket.RESTRICTED.delaysWork && !StandbyBucket.FREQUENT.delaysWork)
    }

    private fun health(
        lastCheck: CheckRecord? = CheckRecord(now, CheckTrigger.BACKGROUND, AgentCheckOutcome.CHECKED),
        bucket: StandbyBucket = StandbyBucket.ACTIVE,
        batteryOptimized: Boolean = false,
        allowed: Boolean = true,
        enabled: Boolean = true,
        watching: Boolean = true,
    ) = BackgroundHealth(lastCheck, bucket, batteryOptimized, allowed, enabled, watching)

    @Test
    fun `todo en orden no avisa de nada`() {
        assertEquals(emptyList(), health().warnings(now.plusSeconds(60)))
    }

    @Test
    fun `avisos en orden de gravedad`() {
        val record = CheckRecord(now, CheckTrigger.BACKGROUND, AgentCheckOutcome.CHECKED, mapOf(ServerCheckResult.LOCAL_NETWORK_BLOCKED to 1))
        val warnings = health(lastCheck = record, bucket = StandbyBucket.RARE, batteryOptimized = true, allowed = false)
            .warnings(now + Duration.ofHours(2))
        assertEquals(
            listOf(
                BackgroundWarning.NOTIFICATIONS_BLOCKED,
                BackgroundWarning.LOCAL_NETWORK_BLOCKED,
                BackgroundWarning.RESTRICTED_BUCKET,
                BackgroundWarning.STALE_CHECK,
                BackgroundWarning.BATTERY_OPTIMIZED,
            ),
            warnings,
        )
    }

    @Test
    fun `sin nada vigilado no se habla de retrasos`() {
        val warnings = health(lastCheck = null, batteryOptimized = true, watching = false).warnings(now)
        assertEquals(emptyList(), warnings)
        assertEquals(listOf(BackgroundWarning.STALE_CHECK), health(lastCheck = null).warnings(now))
        assertEquals(listOf(BackgroundWarning.NOTIFICATIONS_DISABLED), health(enabled = false).warnings(now + Duration.ofHours(3)))
    }
}
