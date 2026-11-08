package com.iaportafolio.argos.core.status

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Paridad con `ArgosTests/ClaudeStatusTests.swift`: parseo de `list-panes`, agregación por
 * sesión/ventana, transiciones notificables y fusión de hooks en settings.json.
 */
class ClaudeStatusTest {

    // Parseo y agregación

    @Test
    fun `parsea list-panes ignorando paneles sin estado y nombres con barra vertical`() {
        val output = listOf("waiting|1|api", "|2|api", "done|1|web|front", "working|3|api", "basura|1|x").joinToString("\n")
        val snapshot = ClaudeActivitySnapshot.fromListPanes(output)
        assertEquals(ClaudeActivity.WAITING, snapshot.activity("api"))
        assertEquals(ClaudeActivity.DONE, snapshot.activity("web|front"))
        assertNull(snapshot.activity("x"))
        assertEquals(mapOf(1 to ClaudeActivity.WAITING, 3 to ClaudeActivity.WORKING), snapshot.windows("api"))
    }

    @Test
    fun `prioridad por sesion esperando sobre terminado sobre trabajando`() {
        assertEquals(ClaudeActivity.DONE, ClaudeActivitySnapshot.fromListPanes("working|1|s\ndone|2|s").activity("s"))
        val withWaiting = ClaudeActivitySnapshot.fromListPanes("done|1|s\nwaiting|2|s\nworking|3|s")
        assertEquals(ClaudeActivity.WAITING, withWaiting.activity("s"))
        assertEquals(ClaudeActivity.WAITING, withWaiting.activity(listOf("otra", "s")))
    }

    @Test
    fun `solo notifica al entrar en esperando o terminado`() {
        val old = ClaudeActivitySnapshot.fromListPanes("working|1|a\nwaiting|1|b\nworking|1|c")
        val new = ClaudeActivitySnapshot.fromListPanes("done|1|a\nwaiting|1|b\nworking|1|c\nwaiting|1|d")
        assertEquals(
            listOf(ClaudeTransition("a", ClaudeActivity.DONE), ClaudeTransition("d", ClaudeActivity.WAITING)),
            new.notableTransitions(old),
        )
    }

    @Test
    fun `sin servidor tmux el estado queda vacio`() {
        assertEquals(ClaudeActivitySnapshot.EMPTY, ClaudeStatusCommands.parseActivity(1, "waiting|1|api"))
        assertEquals(ClaudeActivity.WAITING, ClaudeStatusCommands.parseActivity(0, "waiting|1|api").activity("api"))
    }

    // Hooks en settings.json

    @Test
    fun `instalar anade los hooks y conserva los existentes del usuario`() {
        val existing = """{"model":"opus","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 transcribe.py"}]}]}}"""
        val settings = ClaudeHookInstaller.parseSettings(existing)
        assertFalse(ClaudeHookInstaller.isInstalled(settings))

        val installed = ClaudeHookInstaller.installing(settings)
        assertTrue(ClaudeHookInstaller.isInstalled(installed))
        assertEquals(JsonPrimitive("opus"), installed["model"])

        val hooks = assertNotNull(installed["hooks"] as? JsonObject)
        val submit = assertNotNull(hooks["UserPromptSubmit"] as? JsonArray)
        val commands = submit.flatMap { group ->
            ((group as JsonObject)["hooks"] as JsonArray).mapNotNull { ((it as JsonObject)["command"] as? JsonPrimitive)?.content }
        }
        assertTrue(commands.contains("python3 transcribe.py"))
        assertTrue(commands.any { it.contains(ClaudeHookInstaller.MARKER) })
        for (event in listOf("Stop", "PermissionRequest", "Notification", "PostToolUse", "SessionEnd")) {
            assertNotNull(hooks[event], "falta $event")
        }
    }

    @Test
    fun `instalar dos veces no duplica los hooks`() {
        val once = ClaudeHookInstaller.installing(JsonObject(emptyMap()))
        val twice = ClaudeHookInstaller.installing(once)
        assertEquals(ClaudeHookInstaller.serialize(once), ClaudeHookInstaller.serialize(twice))
    }

    @Test
    fun `desinstalar quita solo los hooks de Argos`() {
        val existing = ClaudeHookInstaller.parseSettings(
            """{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 transcribe.py"}]}]}}""",
        )
        val removed = ClaudeHookInstaller.removing(ClaudeHookInstaller.installing(existing))
        val hooks = assertNotNull(removed["hooks"] as? JsonObject)
        assertEquals(listOf("UserPromptSubmit"), hooks.keys.toList())
        assertFalse(ClaudeHookInstaller.isInstalled(removed))
    }

    @Test
    fun `settings json vacio o inexistente cuenta como objeto vacio`() {
        assertTrue(ClaudeHookInstaller.parseSettings("").isEmpty())
        assertTrue(ClaudeHookInstaller.parseSettings("  \n").isEmpty())
    }

    @Test
    fun `settings json invalido lanza y nunca se sobrescribe a ciegas`() {
        assertFailsWith<ClaudeHookException.InvalidSettings> { ClaudeHookInstaller.parseSettings("{ no es json") }
        assertFailsWith<ClaudeHookException.InvalidSettings> { ClaudeHookInstaller.parseSettings("[1, 2]") }
    }

    @Test
    fun `el comando del hook escribe la opcion en el panel de tmux y nunca falla`() {
        val command = ClaudeHookInstaller.command(ClaudeActivity.WAITING)
        assertTrue(command.contains("tmux set-option -p -t \"\$TMUX_PANE\" @argos_claude waiting"))
        assertTrue(command.contains("exit 0"))
        assertTrue(ClaudeHookInstaller.command(null).contains("set-option -pu"))
    }
}
