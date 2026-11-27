package com.iaportafolio.argos.core.usage

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ClaudeLimitsReadingTests` de Swift: lectura de la statusline, niveles y avisos. */
class ClaudeLimitsTest {

    private val statusLine =
        """{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1800000000},""" +
            """"seven_day":{"used_percentage":8,"resets_at":1800300000},"seven_day_opus":{"used_percentage":91}}}"""

    private fun seconds(value: Long): Instant = Instant.ofEpochSecond(value)

    @Test
    fun `lee las ventanas en orden y pasa la hora de guardado al reloj local`() {
        // El reloj del servidor va 100 s por detrás del local.
        val reading = assertNotNull(
            ClaudeLimitsReading.parse(listOf("now 1799990000", "1799989000", statusLine), localNow = seconds(1_799_990_100)),
        )
        assertEquals(listOf("five_hour", "seven_day", "seven_day_opus"), reading.windows.map { it.kind })
        assertEquals(42.5, reading.windows[0].usedPercent)
        assertEquals(seconds(1_800_000_000), reading.windows[0].resetsAt, "hora de Anthropic: sin corregir")
        assertNull(reading.windows[2].resetsAt)
        assertEquals(seconds(1_799_989_100), reading.capturedAt)
    }

    @Test
    fun `lee la salida entera del sondeo`() {
        val output = "now 1799990000\n1799989000\n$statusLine\n"
        val reading = assertNotNull(ClaudeLimitsReading.parse(output, localNow = seconds(1_799_990_000)))
        assertEquals(3, reading.windows.size)
    }

    @Test
    fun `sin archivo o sin limites no hay lectura`() {
        assertNull(ClaudeLimitsReading.parse(listOf("now 1799990000")))
        assertNull(ClaudeLimitsReading.parse(listOf("now 1799990000", "1799989000", """{"model":{}}""")))
        assertNull(ClaudeLimitsReading.parse(listOf("now 1799990000", "1799989000", "no es json")))
        assertNull(ClaudeLimitsReading.parse(emptyList<String>()))
        assertNull(ClaudeLimitsReading.parse(listOf("now x", "1", statusLine)))
        assertNull(ClaudeLimitsReading.parse(listOf("now 1", "sin hora", statusLine)))
    }

    @Test
    fun `un porcentaje que no es numero no cuenta`() {
        val json = """{"rate_limits":{"five_hour":{"used_percentage":"42"},"seven_day":{"used_percentage":3},"x":5}}"""
        assertEquals(listOf("seven_day"), ClaudeLimitsReading.windows(json)?.map { it.kind })
    }

    @Test
    fun `acepta resets en ISO y en milisegundos`() {
        val iso = """{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":"2027-01-15T10:00:00Z"}}}"""
        val millis = """{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1800000000000}}}"""
        assertEquals(Instant.parse("2027-01-15T10:00:00Z"), ClaudeLimitsReading.windows(iso)?.first()?.resetsAt)
        assertEquals(seconds(1_800_000_000), ClaudeLimitsReading.windows(millis)?.first()?.resetsAt)
    }

    @ParameterizedTest
    @CsvSource("50.0,NORMAL", "84.4,NORMAL", "85.0,HIGH", "94.0,HIGH", "95.0,CRITICAL", "100.0,CRITICAL")
    fun `nivel segun la ventana mas llena`(percent: Double, expected: ClaudeLimitsLevel) {
        val reading = ClaudeLimitsReading.of(
            listOf(ClaudeLimitWindow("five_hour", 10.0, null), ClaudeLimitWindow("seven_day", percent, null)),
            Instant.now(),
        )
        val status = assertNotNull(ClaudeLimitsStatus.evaluate(reading))
        assertEquals(expected, status.level)
        assertEquals("seven_day", status.worst.kind)
    }

    @Test
    fun `con empate manda la primera ventana`() {
        val reading = ClaudeLimitsReading.of(
            listOf(ClaudeLimitWindow("seven_day", 40.0, null), ClaudeLimitWindow("five_hour", 40.0, null)),
            Instant.now(),
        )
        assertEquals("five_hour", ClaudeLimitsStatus.evaluate(reading)?.worst?.kind)
    }

    @Test
    fun `sin ventanas no hay estado`() {
        assertNull(ClaudeLimitsStatus.evaluate(ClaudeLimitsReading.of(emptyList(), Instant.now())))
    }

    @Test
    fun `una ventana ya reiniciada cuenta como cero`() {
        val now = seconds(2_000)
        val reading = ClaudeLimitsReading.of(
            listOf(
                ClaudeLimitWindow("five_hour", 99.0, seconds(1_000)),
                ClaudeLimitWindow("seven_day", 30.0, seconds(9_000)),
            ),
            now,
        )
        val status = assertNotNull(ClaudeLimitsStatus.evaluate(reading, now))
        assertEquals(ClaudeLimitsLevel.NORMAL, status.level)
        assertEquals("seven_day", status.worst.kind)
        assertEquals(30, status.worstPercent)
    }

    private fun reading(vararg windows: Triple<String, Double, Long>) = ClaudeLimitsReading.of(
        windows.map { (kind, percent, reset) -> ClaudeLimitWindow(kind, percent, seconds(reset)) },
        seconds(0),
    )

    private fun alerts(old: List<Triple<String, Double, Long>>?, new: List<Triple<String, Double, Long>>?) =
        ClaudeLimitAlert.transitions(old?.let { reading(*it.toTypedArray()) }, new?.let { reading(*it.toTypedArray()) }, seconds(0))

    @Test
    fun `avisa solo al subir de nivel o con una ventana nueva`() {
        fun five(percent: Double, reset: Long = 5_000) = listOf(Triple("five_hour", percent, reset))
        assertTrue(alerts(five(50.0), five(80.0)).isEmpty())
        assertEquals(listOf(ClaudeLimitsLevel.HIGH), alerts(five(80.0), five(86.0)).map { it.level })
        assertTrue(alerts(five(86.0), five(88.0, reset = 5_030)).isEmpty(), "mismo reinicio con margen")
        assertEquals(listOf(ClaudeLimitsLevel.CRITICAL), alerts(five(88.0), five(96.0)).map { it.level })
        assertTrue(alerts(five(96.0), five(90.0)).isEmpty())
        assertEquals(1, alerts(five(96.0), five(90.0, reset = 30_000)).size, "ventana nueva ya alta")
        assertEquals(1, alerts(null, five(90.0)).size)
        assertTrue(alerts(five(90.0), null).isEmpty())
    }

    @Test
    fun `que cambie la ventana mas llena no repite el aviso de otra`() {
        // La semana ya avisó al 86 %; sube la de 5 h y luego la de 5 h se reinicia.
        val before = listOf(Triple("five_hour", 20.0, 5_000L), Triple("seven_day", 86.0, 90_000L))
        val fiveUp = listOf(Triple("five_hour", 90.0, 5_000L), Triple("seven_day", 86.0, 90_000L))
        val fiveReset = listOf(Triple("five_hour", 3.0, 23_000L), Triple("seven_day", 87.0, 90_000L))
        assertEquals(listOf("five_hour"), alerts(before, fiveUp).map { it.window.kind })
        assertTrue(alerts(fiveUp, fiveReset).isEmpty())
    }

    @Test
    fun `varios avisos a la vez salen del mas grave al menos grave`() {
        val result = alerts(null, listOf(Triple("five_hour", 86.0, 5_000L), Triple("seven_day", 97.0, 90_000L)))
        assertEquals(listOf("seven_day", "five_hour"), result.map { it.window.kind })
        assertEquals(listOf(97, 86), result.map { it.percent })
    }

    @Test
    fun `dentro de una ventana se queda el uso mas alto`() {
        // Otra sesión de Claude, parada, escribió un porcentaje viejo de la misma ventana.
        val fresh = reading(Triple("five_hour", 88.0, 5_000L), Triple("seven_day", 10.0, 90_000L))
        val stale = reading(Triple("five_hour", 60.0, 5_100L), Triple("seven_day", 12.0, 90_000L))
        assertEquals(listOf(88.0, 12.0), stale.merging(fresh).windows.map { it.usedPercent })
        // Con otra ventana (otro reinicio) manda la nueva aunque sea menor.
        val next = reading(Triple("five_hour", 5.0, 23_000L))
        assertEquals(listOf(5.0), next.merging(fresh).windows.map { it.usedPercent })
        assertEquals(stale, stale.merging(null))
    }

    @Test
    fun `una lectura posterior puede bajar el uso de la misma ventana`() {
        val before = reading(Triple("seven_day", 95.0, 90_000L))
        val later = ClaudeLimitsReading.of(listOf(ClaudeLimitWindow("seven_day", 59.0, seconds(90_000))), seconds(600))
        assertEquals(listOf(59.0), later.merging(before).windows.map { it.usedPercent })
    }

    @Test
    fun `el reloj del servidor no mueve el reinicio que da Anthropic`() {
        val reading = assertNotNull(
            ClaudeLimitsReading.parse(
                listOf("now 1000", "990", """{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":5000}}}"""),
                localNow = seconds(2_000),
            ),
        )
        assertEquals(seconds(5_000), reading.windows.first().resetsAt)
        assertEquals(seconds(1_990), reading.capturedAt)
    }

    @Test
    fun `la clave del aviso es estable con el mismo reinicio y nivel`() {
        fun alert(percent: Double, reset: Long) = alerts(null, listOf(Triple("five_hour", percent, reset))).single()
        assertEquals("five_hour-17-1", alert(86.0, 5_010).key)
        assertEquals(alert(86.0, 5_010).key, alert(88.0, 5_020).key)
        assertEquals("five_hour-17-2", alert(96.0, 5_010).key)
    }

    @Test
    fun `misma ventana con margen de reinicio`() {
        val window = ClaudeLimitWindow("five_hour", 1.0, seconds(5_000))
        assertTrue(window.isSameWindow(window.copy(resetsAt = seconds(5_299))))
        assertFalse(window.isSameWindow(window.copy(resetsAt = seconds(5_300))))
        assertFalse(window.isSameWindow(window.copy(kind = "seven_day")))
        assertFalse(window.isSameWindow(window.copy(resetsAt = null)))
        assertTrue(window.copy(resetsAt = null).isSameWindow(window.copy(resetsAt = null)))
    }

    @Test
    fun `el dia del reinicio es hoy manana o mas adelante`() {
        val zone = ZoneId.of("America/Bogota")
        val now = ZonedDateTime.of(2026, 11, 26, 15, 0, 0, 0, zone).toInstant()
        assertEquals(ClaudeLimitResetDay.TODAY, ClaudeLimitReset.day(now.plusSeconds(3 * 3600), now, zone))
        assertEquals(ClaudeLimitResetDay.TOMORROW, ClaudeLimitReset.day(now.plusSeconds(24 * 3600), now, zone))
        assertEquals(ClaudeLimitResetDay.LATER, ClaudeLimitReset.day(now.plusSeconds(4 * 24 * 3600), now, zone))
    }

    @Test
    fun `nombres de las ventanas`() {
        assertEquals(ClaudeLimitLabel.FiveHour, ClaudeLimitWindow("five_hour", 1.0, null).label)
        assertEquals(ClaudeLimitLabel.SevenDay, ClaudeLimitWindow("seven_day", 1.0, null).label)
        assertEquals(ClaudeLimitLabel.SevenDayScoped("Opus"), ClaudeLimitWindow("seven_day_opus", 1.0, null).label)
        assertEquals(ClaudeLimitLabel.SevenDayScoped("Oauth Apps"), ClaudeLimitWindow("seven_day_oauth_apps", 1.0, null).label)
        assertEquals(ClaudeLimitLabel.Other("Monthly Cap"), ClaudeLimitWindow("monthly_CAP", 1.0, null).label)
    }

    @Test
    fun `el porcentaje se recorta entre 0 y 100`() {
        val now = Instant.now()
        assertEquals(100.0, ClaudeLimitWindow("five_hour", 130.0, null).effectivePercent(now))
        assertEquals(0.0, ClaudeLimitWindow("five_hour", -3.0, null).effectivePercent(now))
    }
}
