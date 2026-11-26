package com.iaportafolio.argos.core.usage

import com.iaportafolio.argos.core.agent.stringOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ClaudeLimitsInstallerTests` y `ClaudeLimitsScriptTests` de Swift. */
class ClaudeLimitsInstallerTest {

    private fun statusLine(settings: JsonObject): JsonObject? = settings["statusLine"] as? JsonObject

    private fun userStatusLine(command: String, padding: Int? = null) = buildJsonObject {
        put("statusLine", buildJsonObject {
            put("type", "command")
            put("command", command)
            padding?.let { put("padding", it) }
        })
    }

    // MARK: Fusión de settings.json

    @Test
    fun `sin statusline previa la crea y guarda anterior vacia`() {
        val result = ClaudeLimitsInstaller.installing(buildJsonObject { put("model", "opus") })
        assertEquals(ClaudeLimitsInstaller.COMMAND, statusLine(result.settings)?.get("command").stringOrNull)
        assertEquals("command", statusLine(result.settings)?.get("type").stringOrNull)
        assertEquals("opus", result.settings["model"].stringOrNull)
        assertEquals("", result.previousCommand)
        assertTrue(ClaudeLimitsInstaller.isInstalled(result.settings))
        assertTrue(ClaudeLimitsInstaller.isCurrent(result.settings))
    }

    @Test
    fun `conserva la statusline del usuario y sus opciones`() {
        val result = ClaudeLimitsInstaller.installing(userStatusLine("~/bin/mi-barra.sh", padding = 2))
        assertEquals("~/bin/mi-barra.sh", result.previousCommand)
        assertEquals(JsonPrimitive(2), statusLine(result.settings)?.get("padding"))
        // Quitarla devuelve la del usuario.
        val restored = ClaudeLimitsInstaller.removing(result.settings, "~/bin/mi-barra.sh\n")
        assertEquals("~/bin/mi-barra.sh", statusLine(restored)?.get("command").stringOrNull)
        assertEquals(JsonPrimitive(2), statusLine(restored)?.get("padding"))
    }

    @Test
    fun `instalar dos veces no pisa la anterior guardada`() {
        val first = ClaudeLimitsInstaller.installing(userStatusLine("mi-barra"))
        val second = ClaudeLimitsInstaller.installing(first.settings)
        assertNull(second.previousCommand, "la anterior ya guardada es la del usuario, no la nuestra")
    }

    @Test
    fun `una version antigua cuenta como instalada pero no actual`() {
        val old = userStatusLine("sh ~/.config/argos/otra.sh # argos-claude-limits")
        assertTrue(ClaudeLimitsInstaller.isInstalled(old))
        assertFalse(ClaudeLimitsInstaller.isCurrent(old))
        assertNull(ClaudeLimitsInstaller.installing(old).previousCommand)
    }

    @Test
    fun `quitar sin anterior borra statusline`() {
        val installed = ClaudeLimitsInstaller.installing(JsonObject(emptyMap())).settings
        assertNull(ClaudeLimitsInstaller.removing(installed, "")["statusLine"])
        assertNull(ClaudeLimitsInstaller.removing(installed, null)["statusLine"])
        assertNull(ClaudeLimitsInstaller.removing(installed, " \n")["statusLine"])
    }

    @Test
    fun `quitar no toca una statusline ajena`() {
        val settings = userStatusLine("otra")
        assertEquals(settings, ClaudeLimitsInstaller.removing(settings, "vieja"))
        assertFalse(ClaudeLimitsInstaller.isInstalled(settings))
        assertFalse(ClaudeLimitsInstaller.isInstalled(buildJsonObject { put("statusLine", "texto") }))
    }

    // MARK: Script de la statusline (sh y dash reales)

    private val withLimits = """{"cwd":"/x","rate_limits":{"seven_day":{"used_percentage":8,"resets_at":1796014800}}}"""

    private class Sandbox {
        val home: File = Files.createTempDirectory("argos-limits").toFile()

        init {
            File(home, ".config/argos").mkdirs()
            File(home, ClaudeLimitsInstaller.SCRIPT_RELATIVE_PATH).writeText(ClaudeLimitsInstaller.SCRIPT)
        }

        fun file(relative: String) = File(home, relative)

        fun run(shell: String, input: String): Pair<Int, String> = exec(listOf(shell, file(ClaudeLimitsInstaller.SCRIPT_RELATIVE_PATH).path), input)

        fun exec(command: List<String>, input: String = ""): Pair<Int, String> {
            val builder = ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD)
            builder.environment().apply {
                clear()
                put("HOME", home.path)
                put("PATH", "/usr/bin:/bin")
            }
            val process = builder.start()
            process.outputStream.use { it.write(input.toByteArray(Charsets.UTF_8)) }
            val output = process.inputStream.bufferedReader().readText()
            return process.waitFor() to output
        }

        fun remove() {
            home.deleteRecursively()
        }
    }

    private fun assumeShell(shell: String) = assumeTrue(File(shell).canExecute(), "sin $shell")

    @ParameterizedTest
    @ValueSource(strings = ["/bin/sh", "/bin/dash"])
    fun `guarda los limites y ejecuta la statusline anterior`(shell: String) {
        assumeShell(shell)
        val box = Sandbox()
        try {
            box.file(ClaudeLimitsInstaller.PREVIOUS_RELATIVE_PATH).writeText("printf 'mi barra: '; cat")
            val (status, output) = box.run(shell, withLimits)
            assertEquals(0, status)
            assertEquals("mi barra: $withLimits", output)

            val saved = box.file(ClaudeLimitsInstaller.LIMITS_RELATIVE_PATH)
            val lines = saved.readText().split("\n")
            assertNotNull(lines[0].toLongOrNull())
            assertEquals(withLimits, lines[1])
            assertEquals(
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
                Files.getPosixFilePermissions(saved.toPath()),
            )

            // Y el comando del sondeo lo lee.
            val (_, poll) = box.exec(listOf("/bin/sh", "-c", ClaudeLimitsInstaller.POLL_COMMAND))
            assertEquals(8.0, ClaudeLimitsReading.parse(poll)?.windows?.first()?.usedPercent)
        } finally {
            box.remove()
        }
    }

    @ParameterizedTest
    @ValueSource(strings = ["/bin/sh", "/bin/dash"])
    fun `sin porcentajes no pisa lo guardado y sin anterior no imprime nada`(shell: String) {
        assumeShell(shell)
        val box = Sandbox()
        try {
            box.run(shell, withLimits)
            val before = box.file(ClaudeLimitsInstaller.LIMITS_RELATIVE_PATH).readText()
            val (status, output) = box.run(shell, """{"cwd":"/x","model":{"id":"y"}}""")
            assertEquals(0, status)
            assertEquals("", output)
            assertEquals(before, box.file(ClaudeLimitsInstaller.LIMITS_RELATIVE_PATH).readText())
        } finally {
            box.remove()
        }
    }

    @Test
    fun `el sondeo sin archivo solo da la hora y no hay lectura`() {
        val box = Sandbox()
        try {
            val (status, poll) = box.exec(listOf("/bin/sh", "-c", ClaudeLimitsInstaller.POLL_COMMAND))
            assertEquals(1, status, "cat falla sin archivo; el sondeo lo tolera")
            assertTrue(poll.startsWith("now "))
            assertNull(ClaudeLimitsReading.parse(poll))
        } finally {
            box.remove()
        }
    }
}
