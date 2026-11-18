package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.agent.AgentShellHarness.Companion.isRunning
import com.iaportafolio.argos.core.agent.AgentShellHarness.Companion.waitUntil
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.MethodSource
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Ejecuta DE VERDAD los scripts remotos del agente persistente con un «claude» simulado, en cada
 * shell disponible (en el servidor de compilación `/bin/sh` es dash, como en el del usuario).
 * Port de `ArgosTests/AgentHardeningShellTests.swift`: hibernación, parada con escalado a KILL y
 * al GRUPO, PID reutilizado, envío por stdin de líneas enormes, rotación con un `tail -F`
 * enganchado, fallo al arrancar y avisos con líneas recortadas.
 */
class AgentHardeningShellTest {

    companion object {
        @JvmStatic
        fun shells(): List<String> = AgentShellHarness.shells()

        /**
         * Plazo GENEROSO de las esperas por condición: con la máquina cargada (CI, varios agentes
         * compilando) arrancar un `sh` o un perl tarda; si todo va bien se sale mucho antes.
         */
        const val PATIENCE_SECONDS = 30.0

        /** Antigüedad que se da al log para que cuente como inactivo sin esperar. */
        const val IDLE_LOG_AGE_MILLIS = 10_000L
    }

    // MARK: Arranque

    @ParameterizedTest
    @MethodSource("shells")
    fun `si claude muere al arrancar se dice el porque`(shell: String) = AgentShellHarness(shell).use { h ->
        // El lanzador solo espera 1 s: si claude muere antes, lo dice (`ARGOS_AGENT_FAILED` con su
        // error); si tarda más (máquina cargada), responde su PID y lo detecta el cliente después
        // (`PersistentAgentSession.watchStartup`). Se comprueba el contrato en los dos caminos.
        val run = h.launch(h.fakeClaude(failing = true))
        val line = run.output.trim()
        if (line.startsWith(PersistentAgentScript.FAILED_REPLY)) {
            assertEquals(6, run.status)
            val error = assertFailsWith<PersistentAgentException> { PersistentAgentScript.parseLaunchReply(line) }
            assertEquals(PersistentAgentError.LAUNCH_FAILED, error.error)
            assertEquals("error: unknown option --foo\n", error.detail)
            assertTrue(error.message.orEmpty().contains("unknown option --foo"))
        } else {
            assertTrue(run.status == 0 && line.toIntOrNull() != null, "salida: ${run.output}")
            assertTrue(waitUntil(PATIENCE_SECONDS) { h.listed()?.isAlive == false })
        }
        // En los dos caminos el motivo queda donde el cliente lo lee.
        assertTrue(h.sh(PersistentAgentScript.errorTail(h.id)).output.contains("error: unknown option --foo"))
    }

    // MARK: Hibernación

    @ParameterizedTest
    @MethodSource("shells")
    fun `el vigilante hiberna un agente quieto y se reanuda`(shell: String) = AgentShellHarness(shell).use { h ->
        val invocation = h.fakeClaude()
        val run = h.launch(invocation, PersistentAgentHibernation.of(1, 1))
        assertNotNull(run.output.trim().toIntOrNull(), "salida: ${run.output}")
        h.sh(PersistentAgentScript.send(h.id, """{"n":1}"""))

        assertTrue(waitUntil(PATIENCE_SECONDS) { h.listed()?.let { !it.isAlive && it.meta.isHibernated } ?: false })
        // Con la marca puesta, un envío ya no se da por entregado.
        assertTrue(h.sh(PersistentAgentScript.send(h.id, "{}")).status != 0)
        val decoded = assertNotNull(PersistentAgentMeta.decode(File(h.agentDir, "meta.json").readText()))
        assertTrue(decoded.title == "t" && decoded.hibernatedAt != null)

        // Reanudar (el cliente quita la marca) lo vuelve a poner en marcha.
        h.launch(invocation)
        val info = assertNotNull(h.listed())
        assertTrue(info.isAlive && !info.meta.isHibernated)
        h.sh(PersistentAgentScript.stop(h.id, delete = true))
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `no hiberna si espera un permiso`(shell: String) = AgentShellHarness(shell).use { h ->
        h.launch(h.fakeClaude(), PersistentAgentHibernation.of(1, 1))
        h.sh(PersistentAgentScript.send(h.id, """{"permiso":1}"""))
        // Primero, que el permiso ESTÉ en el log (con la máquina cargada tarda); después, varias
        // vueltas del vigilante (1 s) sin que lo hiberne: esta espera es la prueba en sí.
        assertTrue(waitUntil(PATIENCE_SECONDS) { h.logText().contains("can_use_tool") }, "el permiso no llegó al log")
        Thread.sleep(4_000)
        assertEquals(true, h.listed()?.isAlive)
        // A demanda tampoco: el servidor vuelve a comprobar la quietud.
        val output = h.sh(PersistentAgentScript.hibernate(h.id, 0)).output
        assertFalse(output.contains(PersistentAgentScript.HIBERNATED_REPLY))
        assertEquals(true, h.listed()?.isAlive)
        h.sh(PersistentAgentScript.stop(h.id, delete = true))
        assertFalse(h.agentDir.exists())
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `hibernar a demanda respeta la inactividad minima`(shell: String) = AgentShellHarness(shell).use { h ->
        h.launch(h.fakeClaude())
        h.sh(PersistentAgentScript.send(h.id, """{"n":1}"""))
        // Recién activo: con 1 h de inactividad mínima, no se toca.
        assertFalse(h.sh(PersistentAgentScript.hibernate(h.id, 3600)).output.contains(PersistentAgentScript.HIBERNATED_REPLY))
        assertEquals(true, h.listed()?.isAlive)
        // Que el turno haya acabado (el `result` en el log) y después, que el servidor lo vea quieto
        // al menos 1 s: se reintenta con plazo en vez de suponer cuánto tarda con la máquina cargada.
        assertTrue(waitUntil(PATIENCE_SECONDS) { h.logText().contains("\"type\":\"result\"") }, "el turno no terminó")
        var late = ""
        val hibernated = waitUntil(PATIENCE_SECONDS) {
            late = h.sh(PersistentAgentScript.hibernate(h.id, 1)).output
            late.contains("${PersistentAgentScript.HIBERNATED_REPLY} ${h.id}")
        }
        assertTrue(hibernated, "salida: $late")
        val info = assertNotNull(h.listed())
        assertTrue(!info.isAlive && info.meta.isHibernated)
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `el vigilante no toca un PID reutilizado`(shell: String) = AgentShellHarness(shell).use { h ->
        h.writeMeta()
        File(h.agentDir, "out.ndjson").writeText("""{"type":"result","subtype":"success","is_error":false,"result":"a"}""" + "\n")
        // Un proceso cualquiera (sin el id en su línea de comandos) con el PID guardado.
        val other = ProcessBuilder("/bin/sleep", "30").start()
        try {
            File(h.agentDir, "pid").writeText("${other.pid()}\n")
            // Que el log ya cuente como inactivo, sin depender de cuánto tarde en pasar el tiempo.
            assertTrue(File(h.agentDir, "out.ndjson").setLastModified(System.currentTimeMillis() - IDLE_LOG_AGE_MILLIS))
            val watch = PersistentAgentShell.watchdog(h.id, 1, 1)
            val run = h.sh("sh -c ${ShellQuoting.singleQuoted(watch)} argos-watch ${other.pid()}")
            assertEquals(0, run.status) // sale en cuanto ve que no es el agente
            h.sh(PersistentAgentScript.hibernate(h.id, 0))
            h.sh(PersistentAgentScript.stop(h.id, delete = false, graceSeconds = 1))
            assertTrue(other.isAlive)
            assertFalse(File(h.agentDir, "meta.json").readText().contains("hibernatedAt"))
        } finally {
            other.destroy()
        }
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `marcar hibernado es idempotente y conserva el JSON`(shell: String) = AgentShellHarness(shell).use { h ->
        h.writeMeta(h.meta().copy(permissionMode = "plan"))
        val dir = PersistentAgentScript.directory(h.id)
        h.sh(PersistentAgentShell.markHibernated(dir))
        h.sh(PersistentAgentShell.markHibernated(dir))
        val text = File(h.agentDir, "meta.json").readText()
        assertEquals(2, text.split("hibernatedAt").size) // una sola vez
        val decoded = assertNotNull(PersistentAgentMeta.decode(text))
        assertTrue(decoded.permissionMode == "plan" && decoded.isHibernated)
    }

    // MARK: Parar

    @ParameterizedTest
    @MethodSource("shells")
    fun `parar escala a KILL y solo borra con el proceso muerto`(shell: String) = AgentShellHarness(shell).use { h ->
        val run = h.launch(h.fakeClaude(ignoreTerm = true))
        val pid = assertNotNull(run.output.trim().toLongOrNull(), "salida: ${run.output}")
        assertTrue(isRunning(pid))
        val stop = h.sh(PersistentAgentScript.stop(h.id, delete = true, graceSeconds = 1))
        assertEquals(0, stop.status)
        assertTrue(waitUntil(PATIENCE_SECONDS) { !isRunning(pid) }) // ni con TERM ignorado sobrevive
        assertFalse(h.agentDir.exists())
    }

    /** Con `setsid` claude es líder de su grupo: parar mata también a sus hijos (`kill -s TERM -- -PGID`). */
    @ParameterizedTest
    @MethodSource("shells")
    fun `parar mata al grupo del agente`(shell: String) = AgentShellHarness(shell, setsid = true).use { h ->
        val run = h.launch(h.fakeClaude(child = true))
        val pid = assertNotNull(run.output.trim().toLongOrNull(), "salida: ${run.output}")
        val childFile = File(h.home, "child.pid")
        assertTrue(waitUntil(PATIENCE_SECONDS) { childFile.exists() && childFile.readText().isNotBlank() })
        val child = assertNotNull(childFile.readText().trim().toLongOrNull())
        assertEquals(pid, AgentShellHarness.processGroup(pid)) // líder de su propio grupo
        assertTrue(isRunning(child))
        h.sh(PersistentAgentScript.stop(h.id, delete = false, graceSeconds = 2))
        assertTrue(waitUntil(PATIENCE_SECONDS) { !isRunning(pid) })
        assertTrue(waitUntil(PATIENCE_SECONDS) { !isRunning(child) }) // el hijo cae con el grupo
    }

    // MARK: Envío grande por stdin

    @ParameterizedTest
    @MethodSource("shells")
    fun `una linea enorme llega por stdin y se comprueba su longitud`(shell: String) = AgentShellHarness(shell).use { h ->
        h.launch(h.fakeClaude())
        val line = """{"type":"control_response","response":{"x":"""" + "é".repeat(90_000) + """"}}"""
        assertTrue(PersistentAgentScript.needsStdin(line))
        assertFalse(PersistentAgentScript.needsStdin("{}"))
        val payload = "$line\n".toByteArray()

        val short = h.sh(PersistentAgentScript.sendViaStdin(h.id, payload.size + 1), payload)
        assertTrue(short.output.contains(PersistentAgentScript.SHORT_REPLY))

        val sent = h.sh(PersistentAgentScript.sendViaStdin(h.id, payload.size, "r9"), payload)
        assertTrue(sent.status == 0 && sent.output.contains(PersistentAgentScript.SENT_REPLY), "salida: ${sent.output}")
        val log = File(h.agentDir, "out.ndjson")
        assertTrue(waitUntil(PATIENCE_SECONDS) { runCatching { log.readText() }.getOrDefault("").contains("\"bytes\":") })
        assertTrue(log.readText().contains("\"request_id\":\"r9\""))
        h.sh(PersistentAgentScript.stop(h.id, delete = true))
        val dead = h.sh(PersistentAgentScript.sendViaStdin(h.id, 3), "{}\n".toByteArray())
        assertTrue(dead.output.contains(PersistentAgentScript.DEAD_REPLY))
    }

    /**
     * Más de lo que cabe en la FIFO a un agente que no lee: el script termina al morir el agente o
     * al vencer el plazo. (En Linux reciente la FIFO admite bastante más de 64 KiB: 4 MB la llenan.)
     */
    @ParameterizedTest
    @MethodSource("shells")
    fun `una linea enorme a un agente que no lee no se queda colgada`(shell: String) = AgentShellHarness(shell).use { h ->
        val run = h.launch(h.fakeClaude(deaf = true))
        val pid = assertNotNull(run.output.trim().toLongOrNull(), "salida: ${run.output}")
        val payload = ("z".repeat(4_000_000) + "\n").toByteArray()

        // Vivo pero sin leer: vence el plazo.
        val started = System.nanoTime()
        val timedOut = h.sh(PersistentAgentScript.sendViaStdin(h.id, payload.size, timeoutSeconds = 2), payload)
        assertTrue(timedOut.output.contains(PersistentAgentScript.TIMEOUT_REPLY), "salida: ${timedOut.output}")
        assertTrue(System.nanoTime() - started < 10_000_000_000L)

        // Muere a mitad de la escritura: se detecta enseguida.
        val killer = Thread {
            Thread.sleep(1_000)
            ProcessHandle.of(pid).ifPresent { it.destroyForcibly() }
        }.apply { start() }
        val dead = h.sh(PersistentAgentScript.sendViaStdin(h.id, payload.size, timeoutSeconds = 20), payload)
        killer.join()
        assertTrue(dead.output.contains(PersistentAgentScript.DEAD_REPLY), "salida: ${dead.output}")
        // Ningún escritor `cat` se queda vivo con la línea vieja.
        val leftover = h.sh("ps -eo args= | grep -c '[.]send[.]' || true").output.trim()
        assertEquals("0", leftover)
    }

    // MARK: Rotación

    private fun bigLog(letter: Char): ByteArray {
        val line = """{"type":"assistant","message":{"content":[{"type":"text","text":"""" + letter.toString().repeat(1_000) + "\"}]}}\n"
        return line.repeat(300).toByteArray()
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `la rotacion conserva los desplazamientos absolutos`(shell: String) = AgentShellHarness(shell).use { h ->
        h.writeMeta()
        val original = bigLog('z')
        File(h.agentDir, "out.ndjson").writeBytes(original)
        File(h.agentDir, "log.base").writeText("150\n")
        h.sh(PersistentAgentShell.rotateOutputLog(PersistentAgentScript.directory(h.id), 200_000, 100_000))

        val rotated = File(h.agentDir, "out.ndjson").readBytes()
        val base = assertNotNull(File(h.agentDir, "log.base").readText().trim().toLongOrNull())
        assertTrue(rotated.size <= 100_000)
        assertEquals('{'.code.toByte(), rotated.first()) // empieza en una línea completa
        assertEquals(150L + original.size, base + rotated.size) // la marca no cuenta
        // El log nuevo EMPIEZA por la marca (un `tail -F` que lo reabre la lee primero).
        assertTrue(rotated.toString(Charsets.UTF_8).startsWith(PersistentAgentShell.ROTATED_LINE + "\n"))
        assertFalse(File(h.agentDir, ".rotating").exists())
        assertEquals(150L + original.size, h.listed()?.logBytes)

        fun header(fromByte: Long) = h.sh(PersistentAgentScript.attach(h.id, fromByte)).output.lineSequence().first()
        // El enganche traduce el byte absoluto pedido al local y lo anuncia.
        // (Tras la marca inicial: sus bytes locales nunca se entregan.)
        val mark = PersistentAgentShell.ROTATED_LINE_BYTES
        assertEquals(PersistentAgentScript.LogBase(base, mark + 11L), PersistentAgentScript.parseLogBase(header(base + mark + 11)))
        // Lo pedido ya se rotó: desde el principio de lo conservado (tras la marca).
        val afterMark = PersistentAgentShell.ROTATED_LINE_BYTES + 1L
        assertEquals(afterMark, PersistentAgentScript.parseLogBase(header(5))?.from)
        // Más allá del final (desplazamientos que no cuadran): también reconstruye.
        assertEquals(afterMark, PersistentAgentScript.parseLogBase(header(base + rotated.size + 5_000))?.from)
    }

    /** Bytes del log que ya reenvió el `tail` de [out] (sin su línea de cabecera). */
    private fun readUpTo(out: File): Long {
        val bytes = runCatching { out.readBytes() }.getOrDefault(ByteArray(0))
        val header = bytes.indexOf('\n'.code.toByte())
        return if (header < 0) 0 else (bytes.size - header - 1).toLong()
    }

    /** Un `tail -F` enganchado durante la rotación ve la marca ANTES de la copia conservada. */
    @ParameterizedTest
    @MethodSource("shells")
    fun `rotar con un tail enganchado no infla los desplazamientos`(shell: String) = AgentShellHarness(shell).use { h ->
        h.agentDir.mkdirs()
        val original = bigLog('q')
        File(h.agentDir, "out.ndjson").writeBytes(original)
        // A un archivo (no a una tubería): 400 KB llenarían el búfer y el tail se pararía.
        val outFile = File(h.home, "attach.out")
        val builder = ProcessBuilder(shell, "-c", PersistentAgentScript.attach(h.id))
            .redirectOutput(outFile)
            .redirectError(ProcessBuilder.Redirect.DISCARD)
        builder.environment().apply {
            clear()
            put("HOME", h.home.path)
            put("PATH", h.path)
        }
        val attach = builder.start()
        // Que el tail haya leído TODO (cabecera + log entero) antes de rotar: con la máquina cargada
        // va por detrás, y lo que no leyó del archivo viejo (la marca incluida) ya no lo verá.
        assertTrue(waitUntil(PATIENCE_SECONDS) { readUpTo(outFile) >= original.size })
        h.sh(PersistentAgentShell.rotateOutputLog(PersistentAgentScript.directory(h.id), 200_000, 100_000))
        // tail -F reabre el archivo nuevo y lo reenvía (con la máquina cargada puede tardar).
        waitUntil(PATIENCE_SECONDS) { readUpTo(outFile) > original.size + 50_000 }
        attach.outputStream.close()
        waitUntil(PATIENCE_SECONDS) { !attach.isAlive }
        if (attach.isAlive) attach.destroy()
        val received = outFile.readBytes()

        val parser = AgentAttachStreamParser()
        var counted = 0L
        var sawRotation = false
        for (entry in NdjsonLineBuffer().appendCountingBytes(received).lines) {
            when (parser.classify(entry.text)) {
                AgentAttachStreamParser.Line.Data -> counted += entry.byteCount
                AgentAttachStreamParser.Line.Rotated -> sawRotation = true
                AgentAttachStreamParser.Line.Noise, is AgentAttachStreamParser.Line.Header -> Unit
            }
        }
        assertTrue(sawRotation)
        assertTrue(received.size > original.size + 50_000) // el tail SÍ reenvió la copia…
        assertEquals(original.size.toLong(), counted) // …pero el cliente no la cuenta
    }

    // MARK: Avisos e inventario

    @ParameterizedTest
    @MethodSource("shells")
    fun `un permiso enorme se avisa aunque tool_name venga tarde`(shell: String) = AgentShellHarness(shell).use { h ->
        h.writeMeta()
        val big = "x".repeat(100_000)
        val late = """{"type":"control_request","request_id":"r5","request":{"subtype":"can_use_tool","input":{"content":"""" +
            big + """"},"tool_name":"Write"}}"""
        File(h.agentDir, "out.ndjson").writeText(
            """{"type":"result","subtype":"success","is_error":false,"result":"a"}""" + "\n" + late + "\n",
        )
        val snapshot = assertNotNull(PersistentAgentScript.parseSnapshots(h.sh(PersistentAgentScript.snapshots()).output).firstOrNull())
        assertTrue(snapshot.tail.toByteArray().size < 2_000)
        assertEquals(AgentAttention.NeedsPermission("Write"), AgentAttention.evaluate(snapshot.tail))
    }

    @ParameterizedTest
    @MethodSource("shells")
    fun `el inventario se ejecuta y se entiende`(shell: String) = AgentShellHarness(shell).use { h ->
        h.writeMeta()
        File(h.agentDir, "out.ndjson").writeText("""{"type":"result","subtype":"success","is_error":false,"result":"a"}""" + "\n")
        val run = h.sh(ServerAgentInventory.script())
        assertEquals(0, run.status)
        val agent = assertNotNull(ServerAgentInventory.parse(run.output).agents.firstOrNull { it.sessionID == h.id })
        assertTrue(!agent.isAlive && !agent.hasPendingPermission)
        assertTrue((agent.idleSeconds ?: -1) >= 0)
    }

    /** Parar conversaciones del panel por id: mata la suya y deja en paz otra con otro id. */
    @ParameterizedTest
    @MethodSource("shells")
    fun `parar conversaciones del panel por id`(shell: String) = AgentShellHarness(shell).use { h ->
        val mine = "11111111-2222-3333-4444-555555555555"
        val other = "99999999-2222-3333-4444-555555555555"
        val fake = File(h.home, "claude").apply {
            writeText("#!/usr/bin/perl\nsleep 60;\n")
            setExecutable(true)
        }
        fun spawn(session: String) = ProcessBuilder(
            fake.path, "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--permission-prompt-tool", "stdio", "--session-id", session,
        ).start()
        val target = spawn(mine)
        val bystander = spawn(other)
        try {
            // Que los dos ya se vean en `ps` con su id (con la máquina cargada, perl tarda en arrancar).
            assertTrue(
                waitUntil(PATIENCE_SECONDS) {
                    val listing = h.sh("ps -eo args=").output
                    listing.contains(mine) && listing.contains(other)
                },
                "los procesos del panel no arrancaron",
            )
            h.sh(ServerAgentInventory.stopPanelSessions(listOf(mine)))
            assertTrue(waitUntil(PATIENCE_SECONDS) { !target.isAlive })
            assertTrue(bystander.isAlive)
        } finally {
            bystander.destroy()
            target.destroy()
        }
    }
}
