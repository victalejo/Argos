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

    private fun snap(output: String) = ClaudeActivitySnapshot.fromListPanes(output)

    @Test
    fun `parsea el sondeo ignorando paneles sin estado y nombres con barra vertical`() {
        val output = listOf(
            "-|waiting|%1|1|api", "-||%2|2|api", "-|done|%3|1|web|front", "-|working|%4|3|api", "-|basura|%5|1|x",
            "-|done||1|sin-pane",
        ).joinToString("\n")
        val snapshot = snap(output)
        assertEquals(ClaudeActivity.WAITING, snapshot.activity("api"))
        assertEquals(ClaudeActivity.DONE, snapshot.activity("web|front"))
        assertNull(snapshot.activity("x"))
        assertNull(snapshot.activity("sin-pane"))
        assertEquals(mapOf(1 to ClaudeActivity.WAITING, 3 to ClaudeActivity.WORKING), snapshot.windows("api"))
    }

    @Test
    fun `prioridad por sesion esperando sobre terminado sobre trabajando`() {
        assertEquals(ClaudeActivity.DONE, snap("-|working|%1|1|s\n-|done|%2|2|s").activity("s"))
        val withWaiting = snap("-|done|%1|1|s\n-|waiting|%2|2|s\n-|working|%3|3|s")
        assertEquals(ClaudeActivity.WAITING, withWaiting.activity("s"))
        assertEquals(ClaudeActivity.WAITING, withWaiting.activity(listOf("otra", "s")))
    }

    @Test
    fun `solo notifica al entrar en esperando o terminado`() {
        val old = snap("-|working|%1|1|a\n-|waiting|%2|1|b\n-|working|%3|1|c")
        val new = snap("-|done|%1|1|a\n-|waiting|%2|1|b\n-|working|%3|1|c\n-|waiting|%4|1|d")
        assertEquals(
            listOf(ClaudeTransition("a", 1, ClaudeActivity.DONE), ClaudeTransition("d", 1, ClaudeActivity.WAITING)),
            new.notableTransitions(old),
        )
    }

    @Test
    fun `una ventana ya terminada no oculta el aviso de otra de la sesion`() {
        val old = snap("-|done|%1|1|s\n2|working|%2|2|s")
        val new = snap("-|done|%1|1|s\n-|done|%2|2|s")
        assertEquals(listOf(ClaudeTransition("s", 2, ClaudeActivity.DONE)), new.notableTransitions(old))
        val waiting = snap("-|done|%1|1|s\n-|waiting|%2|2|s")
        assertEquals(listOf(ClaudeTransition("s", 2, ClaudeActivity.WAITING)), waiting.notableTransitions(new))
    }

    @Test
    fun `dos paneles de la misma ventana dan un solo aviso`() {
        assertEquals(
            listOf(ClaudeTransition("s", 1, ClaudeActivity.DONE)),
            snap("-|done|%1|1|s\n-|done|%2|1|s").notableTransitions(ClaudeActivitySnapshot.EMPTY),
        )
    }

    @Test
    fun `interrumpido con Esc pasa a terminado sin avisar`() {
        val old = snap("2|working|%1|1|s")
        val new = snap("0|working|%1|1|s")
        assertEquals(ClaudeActivity.DONE, new.activity("s"))
        assertTrue(new.notableTransitions(old).isEmpty())
        assertEquals(
            listOf(ClaudeTransition("s", 1, ClaudeActivity.DONE)),
            snap("-|done|%1|1|s").notableTransitions(snap("2|working|%1|1|s")),
        )
    }

    @Test
    fun `correccion con la pantalla`() {
        val cases = listOf(
            Triple("working", "2", ClaudeActivity.WORKING), Triple("working", "1", ClaudeActivity.WORKING),
            Triple("working", "0", ClaudeActivity.DONE), Triple("working", "-", ClaudeActivity.WORKING),
            Triple("waiting", "2", ClaudeActivity.WORKING), Triple("waiting", "1", ClaudeActivity.WAITING),
            Triple("waiting", "0", ClaudeActivity.WAITING), Triple("done", "0", ClaudeActivity.DONE),
        )
        for ((hook, screen, expected) in cases) {
            assertEquals(expected, snap("$screen|$hook|%1|1|s").activity("s"), "$hook/$screen")
        }
    }

    @Test
    fun `sin servidor tmux el estado queda vacio`() {
        assertEquals(ClaudeActivitySnapshot.EMPTY, ClaudeStatusCommands.parseActivity(1, "-|waiting|%1|1|api"))
        assertEquals(ClaudeActivity.WAITING, ClaudeStatusCommands.parseActivity(0, "-|waiting|%1|1|api").activity("api"))
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
    fun `cubre interrupciones por error y herramientas fallidas`() {
        val hooks = assertNotNull(ClaudeHookInstaller.installing(JsonObject(emptyMap()))["hooks"] as? JsonObject)
        for (event in listOf("PostToolUseFailure", "PermissionDenied", "StopFailure")) {
            assertNotNull(hooks[event], "falta $event")
        }
    }

    /** Paridad con `detectsOutdatedHooks` de `ClaudeStatusTests.swift` (commit 3a70d15). */
    @Test
    fun `hooks de una version anterior no cuentan como instalados pero si como nuestros`() {
        val installed = ClaudeHookInstaller.installing(JsonObject(emptyMap()))
        val hooks = assertNotNull(installed["hooks"] as? JsonObject)
        val outdated = JsonObject(installed + ("hooks" to JsonObject(hooks - "StopFailure")))
        assertFalse(ClaudeHookInstaller.isInstalled(outdated))
        assertTrue(ClaudeHookInstaller.hasAnyOurs(outdated))
        assertTrue(ClaudeHookInstaller.needsUpgrade(outdated))
        val upgraded = ClaudeHookInstaller.installing(outdated)
        assertTrue(ClaudeHookInstaller.isInstalled(upgraded))
        assertFalse(ClaudeHookInstaller.needsUpgrade(upgraded))
        val foreign = ClaudeHookInstaller.parseSettings(
            """{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say listo"}]}]}}""",
        )
        assertFalse(ClaudeHookInstaller.hasAnyOurs(foreign))
        assertFalse(ClaudeHookInstaller.needsUpgrade(foreign))
    }

    @Test
    fun `un hook nuestro con otro comando o matcher es una version antigua`() {
        val old = ClaudeHookInstaller.parseSettings(
            """{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"tmux viejo # argos-claude-status"}]}]}}""",
        )
        assertFalse(ClaudeHookInstaller.isInstalled(old))
        assertTrue(ClaudeHookInstaller.needsUpgrade(old))
        assertTrue(ClaudeHookInstaller.isInstalled(ClaudeHookInstaller.installing(old)))
        val installed = ClaudeHookInstaller.installing(JsonObject(emptyMap()))
        val hooks = assertNotNull(installed["hooks"] as? JsonObject)
        val notification = assertNotNull(hooks["Notification"] as? JsonArray).single() as JsonObject
        val otherMatcher = JsonObject(notification + ("matcher" to JsonPrimitive("permission_prompt")))
        val changed = JsonObject(installed + ("hooks" to JsonObject(hooks + ("Notification" to JsonArray(listOf(otherMatcher))))))
        assertFalse(ClaudeHookInstaller.isInstalled(changed))
        assertTrue(ClaudeHookInstaller.needsUpgrade(changed))
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
