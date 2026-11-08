package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Paridad con `PersistentAgentScriptTests` de `ArgosTests/PersistentAgentTests.swift`:
 * comandos del relay (FIFO + log) e invocación de claude. Incluye las pruebas que EJECUTAN
 * el lanzador con `/bin/sh` y un claude simulado.
 */
class PersistentAgentScriptTest {

    private val id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private val meta = PersistentAgentMeta("~/proyectos/tienda", "tienda", Instant.ofEpochSecond(1_800_000_000))

    private fun base64Pieces(command: String): List<ByteArray> =
        command.split("'").filter { it.isNotEmpty() }.mapNotNull(SwiftText::decodeBase64)

    @Test
    fun `valida ids`() {
        assertTrue(PersistentAgentScript.isValidID(id))
        assertFalse(PersistentAgentScript.isValidID("../../etc"))
        assertFalse(PersistentAgentScript.isValidID("abc'; rm -rf ~"))
        assertFailsWith<IllegalArgumentException> { PersistentAgentScript.directory("abc'; rm -rf ~") }
    }

    @Test
    fun `lanza con FIFO en lectura-escritura y log`() {
        val command = PersistentAgentScript.launch(id, meta, "env claude -p")
        assertTrue(command.contains("mkfifo in"))
        assertTrue(command.contains("( umask 077 &&")) // umask solo en un subshell
        assertTrue(command.contains("0<>\"\$HOME/.config/argos/agents/$id\"/in"))
        assertTrue(command.contains(">>\"\$HOME/.config/argos/agents/$id\"/out.ndjson"))
        assertTrue(command.contains("nohup \$S sh -c"))
        assertTrue(command.startsWith("IFS= read -r ARGOS_OAUTH")) // token por stdin
        assertTrue(command.contains("ARGOS_AGENT_ALIVE")) // no lanza dos veces
        assertTrue(command.contains(".$id.lock"))
    }

    @Test
    fun `envia en base64 sin interpretar el contenido`() {
        val line = """{"type":"user","message":{"content":"${'$'}(rm -rf ~) `id` 'hola'"}}"""
        val command = PersistentAgentScript.send(id, line)
        assertFalse(command.contains("rm -rf"))
        assertEquals(line + "\n", base64Pieces(command).first().toString(Charsets.UTF_8))
        assertTrue(command.contains("exec 3<>")) // FIFO en lectura-escritura: nunca se bloquea
        assertTrue(command.contains("ARGOS_AGENT_DEAD"))
        assertTrue(command.contains("ps -o args= -p")) // vivo = el pid es DE VERDAD el agente
    }

    @Test
    fun `las respuestas a permisos se anotan en el log despues de entregarlas`() {
        val command = PersistentAgentScript.send(id, "{}", answeredRequestID = "r\"1")
        val parts = command.split(">&3")
        assertEquals(2, parts.size)
        assertTrue(parts[1].contains(">> \"\$HOME/.config/argos/agents/$id\"/out.ndjson"))
        val marker = Json.parseToJsonElement(base64Pieces(parts[1]).first().toString(Charsets.UTF_8))
        val expected = JsonObject(
            mapOf("type" to JsonPrimitive(PersistentAgentScript.ANSWERED_EVENT_TYPE), "request_id" to JsonPrimitive("r\"1")),
        )
        assertEquals(expected, marker)
    }

    @Test
    fun `el tail muere al cerrarse el canal`() {
        val command = PersistentAgentScript.attach(id)
        assertTrue(command.contains("tail -c +1 -F"))
        assertTrue(command.contains("cat > /dev/null; kill \$T"))
    }

    @Test
    fun `parar y borrar`() {
        assertFalse(PersistentAgentScript.stop(id, delete = false).contains("rm -rf"))
        assertTrue(PersistentAgentScript.stop(id, delete = false).contains("grep -q -- '$id'"))
        assertTrue(PersistentAgentScript.stop(id, delete = true).contains("rm -rf \"\$HOME/.config/argos/agents/$id\""))
    }

    @Test
    fun `parsea el listado y descarta basura`() {
        val metaB64 = encodedMeta(meta)
        val older = PersistentAgentMeta("/srv", "viejo", Instant.ofEpochSecond(1))
        val otherID = UUID.randomUUID().toString().uppercase()
        val output = listOf(
            "$otherID|0|10|${encodedMeta(older)}",
            "$id|1|2048|$metaB64",
            "no-es-uuid|1|5|$metaB64",
            "${UUID.randomUUID()}|1|5|esto-no-es-base64",
        ).joinToString("\n")
        val agents = PersistentAgentScript.parseList(output)
        assertEquals(listOf(id, otherID), agents.map { it.id }) // más reciente primero
        assertTrue(agents[0].isAlive && agents[0].logBytes == 2048L && agents[0].meta == meta)
        assertFalse(agents[1].isAlive)
    }

    @Test
    fun `invocacion persistente reenvia los prompts y no lleva el token`() {
        val nueva = ClaudeAgentCommand.persistent("/usr/bin/claude", id, resume = false)
        assertTrue(nueva.startsWith("env -u ANTHROPIC_API_KEY '/usr/bin/claude' -p"))
        assertTrue(nueva.contains("--replay-user-messages"))
        assertTrue(nueva.contains("--session-id $id"))
        assertTrue(nueva.contains("--permission-mode default"))
        assertFalse(nueva.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        assertTrue(ClaudeAgentCommand.persistent("/usr/bin/claude", id, resume = true).contains("--resume $id"))
    }

    @Test
    fun `la respuesta del lanzador distingue arrancado, ocupado y fallo`() {
        assertEquals(PersistentAgentLaunchReply.RUNNING, PersistentAgentScript.parseLaunchReply("4242\n"))
        assertEquals(PersistentAgentLaunchReply.RUNNING, PersistentAgentScript.parseLaunchReply("ARGOS_AGENT_ALIVE\n"))
        assertEquals(PersistentAgentLaunchReply.BUSY, PersistentAgentScript.parseLaunchReply("ARGOS_AGENT_BUSY\n"))
        assertEquals(PersistentAgentLaunchReply.FAILED, PersistentAgentScript.parseLaunchReply("sh: error\n"))
        assertEquals(PersistentAgentLaunchReply.FAILED, PersistentAgentScript.parseLaunchReply(""))
    }

    @Test
    fun `el meta json ida y vuelta conserva los campos (fecha a segundos)`() {
        val withMillis = meta.copy(createdAt = Instant.ofEpochMilli(1_800_000_000_750))
        assertEquals(meta.copy(createdAt = Instant.ofEpochSecond(1_800_000_000)), PersistentAgentMeta.decode(PersistentAgentMeta.encode(withMillis)))
        assertEquals(null, PersistentAgentMeta.decode("""{"title":"x","workingDirectory":"/"}"""))
    }

    /**
     * Ejecuta de verdad el lanzador con `sh`: un «claude» simulado responde por cada línea de
     * la FIFO. Comprueba el log, que sobrevive sin cliente y que se puede parar.
     */
    @Test
    fun `el lanzador funciona de verdad con sh`() {
        val home = Files.createTempDirectory("argos-home-").toFile()
        try {
            val fake = File(home, "claude-falso.sh")
            fake.writeText(
                "#!/bin/sh\n" +
                    "printf '{\"type\":\"token\",\"value\":\"%s\"}\\n' \"\$CLAUDE_CODE_OAUTH_TOKEN\"\n" +
                    "while IFS= read -r line; do printf '{\"type\":\"echo\",\"line\":%s}\\n' \"\$line\"; done\n",
            )
            fake.setExecutable(true)

            val localMeta = PersistentAgentMeta(home.path, "t", Instant.now())
            // Como claude, el proceso lleva el id en su línea de comandos (huella de «vivo»).
            val invocation = "${ShellQuoting.singleQuoted(fake.path)} --session-id $id"
            val launch = PersistentAgentScript.launch(id, localMeta, invocation)
            val pid = shell(launch, home, stdin = "tok-secreto\n").trim()
            assertNotNull(pid.toIntOrNull(), "pid: $pid")
            // Relanzar con el agente vivo no crea otro proceso.
            assertTrue(shell(launch, home, stdin = "\n").contains("ARGOS_AGENT_ALIVE"))

            shell(PersistentAgentScript.send(id, """{"n":1}"""), home)
            shell(PersistentAgentScript.send(id, """{"n":2}""", answeredRequestID = "r2"), home)
            val agentDir = File(home, ".config/argos/agents/$id")
            val logFile = File(agentDir, "out.ndjson")
            var log = ""
            for (attempt in 0 until 150) { // hasta 3 s: el proceso de fondo escribe de forma asíncrona
                log = runCatching { logFile.readText() }.getOrDefault("")
                if (log.contains(""""line":{"n":2}""")) break
                Thread.sleep(20)
            }
            val errLog = runCatching { File(agentDir, "err.log").readText() }.getOrDefault("-")
            assertTrue(log.contains("""{"type":"echo","line":{"n":1}}"""), "log: $log err: $errLog")
            assertTrue(log.contains("""{"type":"echo","line":{"n":2}}"""))
            assertTrue(log.contains("""{"type":"token","value":"tok-secreto"}""")) // el token llega por stdin
            assertTrue(log.contains(""""request_id":"r2"""")) // el permiso respondido queda anotado

            // Instantáneas para los avisos: tamaño del log y su final, ejecutadas de verdad.
            val snapshots = PersistentAgentScript.parseSnapshots(shell(PersistentAgentScript.snapshots(), home))
            assertEquals(listOf(id), snapshots.map { it.id })
            assertEquals(true, snapshots.first().isAlive)
            assertEquals(log.toByteArray().size.toLong(), snapshots.first().logBytes)
            assertTrue(snapshots.first().tail.contains(""""line":{"n":2}"""))

            val listed = PersistentAgentScript.parseList(shell(PersistentAgentScript.list(), home))
            assertEquals(listOf(id), listed.map { it.id })
            assertEquals(true, listed.first().isAlive)

            shell(PersistentAgentScript.stop(id, delete = false), home)
            var alive = true
            for (attempt in 0 until 150) {
                alive = PersistentAgentScript.parseList(shell(PersistentAgentScript.list(), home)).firstOrNull()?.isAlive ?: false
                if (!alive) break
                Thread.sleep(20)
            }
            assertFalse(alive)
            assertFailsWith<IllegalStateException> { shell(PersistentAgentScript.send(id, "{}"), home) }
        } finally {
            home.deleteRecursively()
        }
    }

    /** Un pid guardado que ya NO es el agente (reutilizado tras un reinicio) no se da por vivo ni se mata. */
    @Test
    fun `no mata un proceso ajeno con el mismo pid`() {
        val home = Files.createTempDirectory("argos-home-").toFile()
        val ajeno = ProcessBuilder("/bin/sleep", "30").start()
        try {
            val dir = File(home, ".config/argos/agents/$id").apply { mkdirs() }
            File(dir, "pid").writeText("${ajeno.pid()}\n")
            File(dir, "meta.json").writeText(PersistentAgentMeta.encode(meta))

            shell(PersistentAgentScript.stop(id, delete = false), home)
            assertTrue(ajeno.isAlive)
            assertEquals(false, PersistentAgentScript.parseList(shell(PersistentAgentScript.list(), home)).firstOrNull()?.isAlive)
        } finally {
            ajeno.destroy()
            home.deleteRecursively()
        }
    }

    private fun encodedMeta(meta: PersistentAgentMeta): String =
        SwiftText.encodeBase64(PersistentAgentMeta.encode(meta).toByteArray())

    /** Ejecuta [command] con `/bin/sh -c` y un entorno mínimo; falla si el código no es 0. */
    private fun shell(command: String, home: File, stdin: String? = null): String {
        val builder = ProcessBuilder("/bin/sh", "-c", command).redirectError(ProcessBuilder.Redirect.DISCARD)
        builder.environment().apply {
            clear()
            put("HOME", home.path)
            put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        }
        val process = builder.start()
        process.outputStream.use { out -> stdin?.let { out.write(it.toByteArray()) } }
        val output = process.inputStream.bufferedReader().readText()
        val status = process.waitFor()
        check(status == 0) { "sh salió con $status" }
        return output
    }
}
