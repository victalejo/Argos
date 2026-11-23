package com.iaportafolio.argos.core.monitor

import com.iaportafolio.argos.core.monitor.ServerMemoryPressureLevel.CRITICAL
import com.iaportafolio.argos.core.monitor.ServerMemoryPressureLevel.HIGH
import com.iaportafolio.argos.core.monitor.ServerMemoryPressureLevel.NORMAL
import org.junit.jupiter.api.Assumptions.assumeTrue
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ServerMemoryPressure.swift`: lectura, fracción libre, niveles con histéresis y aviso. */
class ServerMemoryPressureTest {

    /** Fracción libre exacta: sin swap, disponible = [free] × 1 000 000 KB. */
    private fun reading(free: Double, claude: Int? = null) =
        ServerMemoryReading(1_000_000, (free * 1_000_000).toLong(), 0, 0, claude)

    // MARK: - Comando

    @Test
    fun `el comando es byte a byte el de Swift`() {
        val expected = """awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2} END{if(t>0) print "mem", t, a+0, st+0, sf+0}' /proc/meminfo 2>/dev/null; printf 'claude %s\n' "$(pgrep -x -u "$(id -u)" claude 2>/dev/null | wc -l | tr -d ' ')""""
        assertEquals(expected, ServerMemoryPressure.COMMAND)
    }

    @Test
    fun `el comando corre bajo sh y su salida se puede leer`() {
        assumeTrue(File("/proc/meminfo").exists(), "Solo en Linux")
        val process = ProcessBuilder("/bin/sh", "-c", ServerMemoryPressure.COMMAND).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        assertEquals(0, process.waitFor())
        val parsed = assertNotNull(ServerMemoryReading.parse(output), output)
        assertTrue(parsed.totalKB > 0)
        assertNotNull(parsed.claudeProcesses)
    }

    // MARK: - Lectura

    @Test
    fun `lee la salida completa`() {
        val parsed = ServerMemoryReading.parse("mem 12247536 4599232 4194300 1048576\nclaude 18\n")
        assertEquals(ServerMemoryReading(12_247_536, 4_599_232, 4_194_300, 1_048_576, 18), parsed)
    }

    @Test
    fun `sin línea claude la lectura vale sin procesos`() {
        val parsed = ServerMemoryReading.parse("mem 1000 500 0 0")
        assertEquals(ServerMemoryReading(1000, 500, 0, 0, null), parsed)
    }

    @Test
    fun `una línea claude rara no invalida la memoria`() {
        assertNull(ServerMemoryReading.parse("mem 1000 500 0 0\nclaude x")?.claudeProcesses)
    }

    @Test
    fun `sin línea mem válida no hay lectura`() {
        assertNull(ServerMemoryReading.parse("claude 3\n"), "no Linux: solo llega la línea claude")
        assertNull(ServerMemoryReading.parse(""))
        assertNull(ServerMemoryReading.parse("mem 1000 500 0\nclaude 1"), "faltan campos")
        assertNull(ServerMemoryReading.parse("mem 1000 500 0 0 9"), "sobran campos")
        assertNull(ServerMemoryReading.parse("mem 1000 abc 0 0"), "no numérico")
        assertNull(ServerMemoryReading.parse("mem 1000 -5 0 0"), "negativo")
    }

    @Test
    fun `con total 0 no hay lectura`() {
        assertNull(ServerMemoryReading.parse("mem 0 0 0 0\nclaude 2"))
    }

    // MARK: - Fracción y porcentaje

    @Test
    fun `la fracción libre suma RAM y swap`() {
        val r = ServerMemoryReading(totalKB = 12_000, availableKB = 1_000, swapTotalKB = 4_000, swapFreeKB = 1_000)
        assertEquals(0.125, r.freeFraction, 1e-9)
        assertEquals(88, r.usedPercent)
    }

    @Test
    fun `la fracción se acota entre 0 y 1`() {
        assertEquals(1.0, ServerMemoryReading(100, 500, 0, 0).freeFraction)
        assertEquals(0, ServerMemoryReading(100, 500, 0, 0).usedPercent)
        assertEquals(0.0, ServerMemoryReading(100, 0, 0, 0).freeFraction)
        assertEquals(100, ServerMemoryReading(100, 0, 0, 0).usedPercent)
    }

    @Test
    fun `sin denominador la fracción libre es 1`() {
        assertEquals(1.0, ServerMemoryReading(0, 0, 0, 0).freeFraction)
    }

    @Test
    fun `el porcentaje usado se redondea`() {
        assertEquals(83, reading(0.174).usedPercent)
        assertEquals(83, reading(0.166).usedPercent)
    }

    // MARK: - Niveles

    @Test
    fun `evalúa cada umbral`() {
        assertEquals(CRITICAL, ServerMemoryPressure.evaluate(reading(0.05)))
        assertEquals(CRITICAL, ServerMemoryPressure.evaluate(reading(0.0999)))
        assertEquals(HIGH, ServerMemoryPressure.evaluate(reading(0.10)))
        assertEquals(HIGH, ServerMemoryPressure.evaluate(reading(0.1999)))
        assertEquals(NORMAL, ServerMemoryPressure.evaluate(reading(0.20)))
        assertEquals(NORMAL, ServerMemoryPressure.evaluate(reading(0.5)))
    }

    @Test
    fun `sin lectura es normal`() {
        assertEquals(NORMAL, ServerMemoryPressure.evaluate(null, CRITICAL))
    }

    @Test
    fun `histéresis al bajar de un aviso`() {
        assertEquals(HIGH, ServerMemoryPressure.evaluate(reading(0.22), HIGH))
        assertEquals(HIGH, ServerMemoryPressure.evaluate(reading(0.22), CRITICAL))
        assertEquals(NORMAL, ServerMemoryPressure.evaluate(reading(0.22)))
        assertEquals(NORMAL, ServerMemoryPressure.evaluate(reading(0.22), NORMAL))
        assertEquals(NORMAL, ServerMemoryPressure.evaluate(reading(0.26), HIGH))
        assertEquals(NORMAL, ServerMemoryPressure.evaluate(reading(0.25), HIGH))
    }

    @Test
    fun `la histéresis no rebaja un crítico ni sube de nivel`() {
        assertEquals(CRITICAL, ServerMemoryPressure.evaluate(reading(0.05), HIGH))
        assertEquals(HIGH, ServerMemoryPressure.evaluate(reading(0.15), CRITICAL))
    }

    @Test
    fun `solo el crítico pide confirmación al arrancar`() {
        assertTrue(ServerMemoryPressure.needsConfirmationToStart(CRITICAL))
        assertFalse(ServerMemoryPressure.needsConfirmationToStart(HIGH))
        assertFalse(ServerMemoryPressure.needsConfirmationToStart(NORMAL))
    }

    // MARK: - Aviso

    @Test
    fun `el aviso lleva nivel, porcentaje y procesos de Claude`() {
        val warning = assertNotNull(ServerMemoryPressure.warning(reading(0.08, claude = 20), CRITICAL))
        assertEquals(ServerMemoryWarning(CRITICAL, 92, 20), warning)
        assertTrue(warning.needsConfirmationToStart)
        assertEquals(20, warning.citedClaudeProcesses)
    }

    @Test
    fun `sin procesos de Claude el aviso no los cita`() {
        assertNull(ServerMemoryPressure.warning(reading(0.15, claude = 0), HIGH)?.citedClaudeProcesses)
        assertNull(ServerMemoryPressure.warning(reading(0.15), HIGH)?.citedClaudeProcesses)
        assertFalse(assertNotNull(ServerMemoryPressure.warning(reading(0.15), HIGH)).needsConfirmationToStart)
    }

    @Test
    fun `en nivel normal o sin lectura no hay aviso`() {
        assertNull(ServerMemoryPressure.warning(reading(0.5), NORMAL))
        assertNull(ServerMemoryPressure.warning(null, CRITICAL))
    }
}
