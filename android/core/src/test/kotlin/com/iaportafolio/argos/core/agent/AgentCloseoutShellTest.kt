package com.iaportafolio.argos.core.agent

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.MethodSource
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Cierre de flecos (port de `ArgosTests/AgentHardeningRound3Tests.swift`): la marca de rotación ya
 * no depende de una carrera (el log nuevo EMPIEZA por ella) y el envío y la hibernación son
 * atómicos (mismo cerrojo y el envío toca el log). Sin esperas fijas: lo que antes dependía de la
 * carga se reproduce a mano.
 */
class AgentCloseoutShellTest {

    companion object {
        @JvmStatic
        fun shells(): List<String> = AgentShellHarness.shells()

        const val PATIENCE_SECONDS = 30.0
        private const val RESULT_LINE = """{"type":"result","subtype":"success","is_error":false,"result":"ok"}"""
    }

    private fun bigLog(letter: Char): ByteArray {
        val line = """{"type":"assistant","message":{"content":[{"type":"text","text":"""" + letter.toString().repeat(1_000) + "\"}]}}\n"
        return line.repeat(300).toByteArray()
    }

    private fun AgentShellHarness.header(fromByte: Long): PersistentAgentScript.LogBase? =
        PersistentAgentScript.parseLogBase(sh(PersistentAgentScript.attach(id, fromByte)).output.lineSequence().first())

    private fun AgentShellHarness.rotateSmall() =
        sh(PersistentAgentShell.rotateOutputLog(PersistentAgentScript.directory(id), 200_000, 100_000))

    private fun AgentShellHarness.isAlive(): Boolean =
        sh("if ${PersistentAgentScript.aliveCheck(id)}; then echo vivo; fi").output.contains("vivo")

    private val AgentShellHarness.lockDir: File get() = File(home, ".config/argos/agents/.$id.lock")

    // MARK: Rotación

    @ParameterizedTest
    @MethodSource("shells")
    fun `el log rotado empieza por la marca y el enganche la salta`(shell: String) = AgentShellHarness(shell).use { h ->
        h.writeMeta()
        val original = bigLog('z')
        File(h.agentDir, "out.ndjson").writeBytes(original)
        File(h.agentDir, "log.base").writeText("150\n")
        h.rotateSmall()

        val rotated = File(h.agentDir, "out.ndjson").readBytes()
        val mark = PersistentAgentShell.ROTATED_LINE_BYTES
        assertContentEquals("${PersistentAgentShell.ROTATED_LINE}\n".toByteArray(), rotated.copyOfRange(0, mark))
        val base = assertNotNull(File(h.agentDir, "log.base").readText().trim().toLongOrNull())
        assertEquals(150L + original.size, base + rotated.size) // el tamaño absoluto no cambia
        // Lo conservado (tras la marca) es el FINAL exacto del original, en su byte absoluto.
        val kept = rotated.copyOfRange(mark, rotated.size)
        assertContentEquals(original.copyOfRange(original.size - kept.size, original.size), kept)
        assertEquals(150L + original.size - kept.size, base + mark)

        val fresh = assertNotNull(h.header(1))
        assertEquals(PersistentAgentScript.LogBase(base, mark + 1L), fresh)
        val firstData = h.sh(PersistentAgentScript.attach(h.id)).output.lineSequence().drop(1).first()
        assertFalse(AgentAttachStreamParser.isRotationMarker(firstData))
        val exact = assertNotNull(h.header(base + mark + 1))
        assertEquals(base + mark, exact.base + exact.from - 1)
        assertEquals(rotated.size + 1L, h.header(base + rotated.size + 1)?.from)
    }

    /**
     * El peor caso de la carrera, sin depender de la carga: el `tail -F` NO leyó la marca del
     * archivo viejo y reenvía el nuevo entero. El cliente para de contar en la marca inicial y,
     * al reengancharse con sus bytes, sigue justo donde estaba.
     */
    @ParameterizedTest
    @MethodSource("shells")
    fun `un tail que no vio la marca del viejo no infla los desplazamientos`(shell: String) = AgentShellHarness(shell).use { h ->
        h.writeMeta()
        val original = bigLog('q')
        File(h.agentDir, "out.ndjson").writeBytes(original)
        val firstHeader = h.sh(PersistentAgentScript.attach(h.id)).output.lineSequence().first()
        h.rotateSmall()
        val replaced = File(h.agentDir, "out.ndjson").readBytes()

        val stream = "$firstHeader\n".toByteArray() + original + replaced
        val parser = AgentAttachStreamParser()
        var counted = 0L
        var rotations = 0
        for (entry in NdjsonLineBuffer().appendCountingBytes(stream).lines) {
            when (parser.classify(entry.text)) {
                AgentAttachStreamParser.Line.Data -> counted += entry.byteCount
                AgentAttachStreamParser.Line.Rotated -> rotations++
                AgentAttachStreamParser.Line.Noise, is AgentAttachStreamParser.Line.Header -> Unit
            }
        }
        assertEquals(1, rotations)
        assertEquals(original.size.toLong(), counted)
        val next = assertNotNull(h.header(counted + 1))
        assertEquals(counted, next.base + next.from - 1)
    }

    // MARK: Envío frente a hibernación

    @ParameterizedTest
    @MethodSource("shells")
    fun `el envio espera al vigilante y si hiberna dice muerto`(shell: String) = AgentShellHarness(shell).use { h ->
        h.launch(h.fakeClaude(deaf = true))
        assertTrue(h.lockDir.mkdir())
        val builder = ProcessBuilder(shell, "-c", PersistentAgentScript.send(h.id, """{"n":1}"""))
            .redirectOutput(ProcessBuilder.Redirect.DISCARD)
        builder.environment().apply {
            clear()
            put("HOME", h.home.path)
            put("PATH", h.path)
        }
        val sender = builder.start()
        sender.outputStream.close()
        // Lo que haría el vigilante con el cerrojo: anotar la hibernación y soltarlo.
        h.sh(PersistentAgentShell.markHibernated(PersistentAgentScript.directory(h.id)))
        assertTrue(h.lockDir.delete())
        assertTrue(sender.waitFor(PATIENCE_SECONDS.toLong(), TimeUnit.SECONDS))
        assertEquals(3, sender.exitValue())
        assertTrue(sender.errorStream.readBytes().toString(Charsets.UTF_8).contains(PersistentAgentScript.DEAD_REPLY))
        assertFalse(h.lockDir.exists())
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `tras enviar el agente no se ve quieto`(shell: String) = AgentShellHarness(shell).use { h ->
        h.launch(h.fakeClaude(deaf = true))
        val log = File(h.agentDir, "out.ndjson")
        for (useStdin in listOf(false, true)) {
            log.writeText(RESULT_LINE + "\n")
            assertTrue(log.setLastModified(System.currentTimeMillis() - 3_600_000))
            if (useStdin) {
                val payload = ("x".repeat(8_000) + "\n").toByteArray()
                val sent = h.sh(PersistentAgentScript.sendViaStdin(h.id, payload.size, timeoutSeconds = 5), payload)
                assertTrue(sent.output.contains(PersistentAgentScript.SENT_REPLY), "salida: ${sent.output}")
            } else {
                assertEquals(0, h.sh(PersistentAgentScript.send(h.id, """{"n":1}""")).status)
            }
            assertTrue(System.currentTimeMillis() - log.lastModified() < PATIENCE_SECONDS * 1_000)
            val output = h.sh(PersistentAgentScript.hibernate(h.id, 600)).output
            assertFalse(output.contains(PersistentAgentScript.HIBERNATED_REPLY))
            assertTrue(h.isAlive())
        }
        assertFalse(h.lockDir.exists())
    }
}
