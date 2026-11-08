package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.agent.AgentProtocol
import com.iaportafolio.argos.core.agent.AgentStreamEvent
import com.iaportafolio.argos.ssh.testing.FakeClaude
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.io.TempDir
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.TimeUnit
import kotlin.io.path.exists
import kotlin.io.path.writeBytes
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * El script del `claude` simulado bajo cada shell POSIX disponible (dash es el `/bin/sh` de la CI,
 * y macOS trae `/bin/dash` y un `/bin/sh` distinto), sin SSH de por medio.
 */
class FakeClaudeScriptTest {

    private class Run(val exitCode: Int, val stdout: String, val stderr: String)

    @ParameterizedTest
    @ValueSource(strings = ["/bin/sh", "/bin/dash"])
    fun `reproduce el guion completo con un stream-json que entiende AgentProtocol`(shell: String, @TempDir home: Path) {
        val session = "11111111-1111-4111-8111-111111111111"
        val user = AgentProtocol.encodeUserMessage("hola \"mundo\" ñ")
        val response = """{"response":{"request_id":"00000000-0000-4000-8000-000000000001",""" +
            """"response":{"behavior":"allow","updatedInput":{}},"subtype":"success"},"type":"control_response"}"""
        val second = AgentProtocol.encodeUserMessage("otra vez")

        val run = runScript(shell, home, listOf(user, response, second), persistentFlags(session))

        assertEquals(0, run.exitCode, run.stderr)
        val events = run.stdout.lines().filter { it.isNotEmpty() }.map { line ->
            assertTrue(line.startsWith("{") && line.endsWith("}"), line)
            checkNotNull(AgentProtocol.decode(line)) { "Línea no válida: $line" }
        }
        assertIs<AgentStreamEvent.PermissionRequest>(events.first { it is AgentStreamEvent.PermissionRequest })
        assertEquals(2, events.count { it is AgentStreamEvent.Result })
        val echo = assertIs<AgentStreamEvent.User>(events.first { it is AgentStreamEvent.User })
        assertContains(echo.blocks.toString(), "hola \"mundo\" ñ")
        assertTrue(home.resolve("notas-argos-1.md").exists(), "Al aprobar crea el archivo")
        assertTrue(run.stdout.contains("\"cwd\":\"$home\"") || run.stdout.contains("\"cwd\":\"${home.toRealPath()}\""))
    }

    @ParameterizedTest
    @ValueSource(strings = ["/bin/sh", "/bin/dash"])
    fun `sin el modo test no escribe nunca el token en disco`(shell: String, @TempDir home: Path) {
        val run = runScript(
            shell, home, listOf(AgentProtocol.encodeUserMessage("#lento hola")),
            persistentFlags("22222222-2222-4222-8222-222222222222"),
            extraEnvironment = mapOf("CLAUDE_CODE_OAUTH_TOKEN" to "secreto"),
        )

        assertEquals(0, run.exitCode, run.stderr)
        val leaked = home.toFile().walkTopDown().filter { it.isFile && it.name != "claude" }.filter { "secreto" in it.readText() }
        assertEquals(emptyList(), leaked.toList())
    }

    @ParameterizedTest
    @ValueSource(strings = ["/bin/sh", "/bin/dash"])
    fun `rechaza flags desconocidos o incompletos como el CLI`(shell: String, @TempDir home: Path) {
        val unknown = runScript(shell, home, emptyList(), listOf("--no-existe"))
        assertEquals(2, unknown.exitCode)
        assertContains(unknown.stderr, "unknown option")

        val incomplete = runScript(shell, home, emptyList(), listOf("-p", "--session-id", "x"))
        assertEquals(2, incomplete.exitCode)
    }

    @ParameterizedTest
    @ValueSource(strings = ["/bin/sh", "/bin/dash"])
    fun `auth status dice logueado salvo con el archivo marcador`(shell: String, @TempDir home: Path) {
        val logged = runScript(shell, home, emptyList(), listOf("auth", "status", "--json"))
        assertEquals(0, logged.exitCode)
        assertContains(logged.stdout, "\"loggedIn\":true")

        Files.createFile(home.resolve(FakeClaude.LOGGED_OUT_MARKER))

        val out = runScript(shell, home, emptyList(), listOf("auth", "status", "--json"))
        assertEquals(1, out.exitCode)
        assertContains(out.stdout, "\"loggedIn\":false")
    }

    private fun persistentFlags(session: String): List<String> = listOf(
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--permission-prompt-tool", "stdio", "--replay-user-messages", "--permission-mode", "default",
        "--session-id", session,
    )

    private fun runScript(
        shell: String,
        home: Path,
        input: List<String>,
        args: List<String>,
        extraEnvironment: Map<String, String> = emptyMap(),
    ): Run {
        assumeTrue(Files.isExecutable(Path.of(shell)), "Sin $shell")
        val script = Files.createTempFile("claude-simulado", ".sh").apply { writeBytes(FakeClaude.script()) }
        try {
            val stderr = Files.createTempFile("claude-simulado", ".err")
            val process = ProcessBuilder(listOf(shell, script.toString()) + args)
                .directory(home.toFile())
                .redirectError(stderr.toFile())
                .apply {
                    environment().clear()
                    environment()["HOME"] = home.toString()
                    environment()["PATH"] = "/usr/bin:/bin"
                    environment().putAll(extraEnvironment)
                }
                .start()
            process.outputStream.use { stream -> input.forEach { stream.write("$it\n".toByteArray()) } }
            val stdout = process.inputStream.bufferedReader().readText()
            check(process.waitFor(WAIT_SECONDS, TimeUnit.SECONDS)) { "El script no terminó" }
            val errors = Files.readString(stderr).also { Files.delete(stderr) }
            return Run(process.exitValue(), stdout, errors)
        } finally {
            Files.delete(script)
        }
    }

    private companion object {
        const val WAIT_SECONDS = 30L
    }
}
