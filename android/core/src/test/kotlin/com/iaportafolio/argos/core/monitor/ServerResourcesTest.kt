package com.iaportafolio.argos.core.monitor

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Paridad con `ArgosTests/ServerResourcesTests.swift`. El fixture es una salida REAL del
 * comando del monitor en un Ubuntu 24.04 (servidor dev).
 */
class ServerResourcesTest {

    private val fixture = """
        5.73 3.99 3.32 4/999 196002
        @@
        cpu  843449 111347 948277 85909046 80717 0 185867 0 0 0
        @@
        MemTotal:       12247536 kB
        MemAvailable:    4599232 kB
        SwapTotal:             0 kB
        SwapFree:              0 kB
        @@
        6
        @@
        148367.93
        @@
        /dev/sda1        202051056 40518928 161515744      21% /
        @@
         195744  355  6.5 next-build (v16
         196009  300  0.0 ps
          74023 16.7  4.0 claude
    """.trimIndent()

    @Test
    fun `parsea carga nucleos y uptime`() {
        val s = ServerResourceParser.parse(fixture)
        assertEquals(5.73, s.load1)
        assertEquals(3.99, s.load5)
        assertEquals(3.32, s.load15)
        assertEquals(6, s.cores)
        assertEquals(148_367L, s.uptimeSeconds)
    }

    @Test
    fun `parsea memoria usada igual a total menos disponible`() {
        val s = ServerResourceParser.parse(fixture)
        assertEquals(12_247_536L, s.memory.totalKB)
        assertEquals(12_247_536L - 4_599_232L, s.memory.usedKB)
        assertEquals(0L, s.swap.totalKB)
        assertEquals(0.0, s.swap.fraction)
    }

    @Test
    fun `parsea disco raiz`() {
        val s = ServerResourceParser.parse(fixture)
        assertEquals(202_051_056L, s.disk.totalKB)
        assertEquals(40_518_928L, s.disk.usedKB)
    }

    @Test
    fun `ticks de CPU idle incluye iowait y total suma los 8 primeros campos`() {
        val s = ServerResourceParser.parse(fixture)
        assertEquals(85_909_046L + 80_717L, s.cpu.idle)
        assertEquals(843_449L + 111_347L + 948_277L + 85_909_046L + 80_717L + 0 + 185_867L + 0, s.cpu.total)
    }

    @Test
    fun `procesos el nombre puede contener espacios`() {
        val s = ServerResourceParser.parse(fixture)
        assertEquals(3, s.topProcesses.size)
        assertEquals(195_744, s.topProcesses[0].pid)
        assertEquals(355.0, s.topProcesses[0].cpuPercent)
        assertEquals(6.5, s.topProcesses[0].memPercent)
        assertEquals("next-build (v16", s.topProcesses[0].command)
        assertEquals("claude", s.topProcesses[2].command)
    }

    @Test
    fun `uso de CPU entre dos muestras`() {
        val a = CpuTicks(total = 1000, idle = 800)
        val b = CpuTicks(total = 1200, idle = 850)
        assertEquals(0.75, b.usageSince(a))
    }

    @Test
    fun `sin avance de ticks o contador reiniciado no hay uso calculable`() {
        val a = CpuTicks(total = 1000, idle = 800)
        assertNull(a.usageSince(a))
        assertNull(CpuTicks(total = 10, idle = 5).usageSince(a))
    }

    @Test
    fun `salida sin proc o incompleta lanza unsupported`() {
        assertFailsWith<ServerResourceException.Unsupported> { ServerResourceParser.parse("") }
        assertFailsWith<ServerResourceException.Unsupported> { ServerResourceParser.parse("5.0 4.0 3.0 1/2 3\n@@\n") }
    }

    @ParameterizedTest
    @CsvSource(
        "148367.93, inf", "148367.93, nan", "148367.93, Infinity", "148367.93, NaN", "148367.93, -5",
        "148367.93, 1e300", "843449, 9223372036854775807", "843449, -1",
    )
    fun `valores hostiles se rechazan sin abortar`(original: String, replacement: String) {
        val hostile = fixture.replace(original, replacement)
        assertFailsWith<ServerResourceException.Unsupported> { ServerResourceParser.parse(hostile) }
    }

    @Test
    fun `memoria disponible mayor que la total se rechaza`() {
        val hostile = fixture.replace("4599232", "99999999")
        assertFailsWith<ServerResourceException.Unsupported> { ServerResourceParser.parse(hostile) }
    }

    @ParameterizedTest
    @CsvSource(
        delimiter = '|',
        value = ["512|512 KB", "2048|2,0 MB", "12247536|11,7 GB", "202051056|192,7 GB"],
    )
    fun `formato de bytes legible`(kb: Long, expected: String) {
        assertEquals(expected, ResourceFormat.kilobytes(kb))
    }

    @ParameterizedTest
    @CsvSource("59, 59 s", "3600, 1 h 0 min", "148367, 1 d 17 h", "120, 2 min")
    fun `uptime legible`(seconds: Long, expected: String) {
        assertEquals(expected, ResourceFormat.uptime(seconds))
    }

    @Test
    fun `porcentaje redondeado`() {
        assertEquals("38 %", ResourceFormat.percent(0.375))
        assertEquals("0 %", ResourceFormat.percent(0.0))
    }

    @Test
    fun `el comando une las secciones con el separador`() {
        val command = ServerResourceParser.RESOURCES_COMMAND
        assertTrue(command.startsWith("cat /proc/loadavg && echo '@@' && head -1 /proc/stat && echo '@@' && "))
        assertTrue(command.endsWith("echo '@@' && ps -eo pid=,pcpu=,pmem=,comm= --sort=-pcpu | head -8"))
        assertEquals(6, Regex("echo '@@'").findAll(command).count())
    }
}
