package com.iaportafolio.argos.core.agent

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/ClaudeAgentCommandTests.swift` y `AgentAuthParsingTests.swift`. */
class ClaudeAgentCommandTest {

    @Test
    fun `incluye las banderas del protocolo de control`() {
        val command = ClaudeAgentCommand.build(
            claudePath = "/usr/bin/claude",
            workingDirectory = "/home/u/repo",
            sessionID = "11111111-1111-1111-1111-111111111111",
        )
        assertTrue(command.contains("--input-format stream-json"))
        assertTrue(command.contains("--output-format stream-json"))
        assertTrue(command.contains("--permission-prompt-tool stdio"))
        assertTrue(command.contains("--session-id 11111111-1111-1111-1111-111111111111"))
    }

    @Test
    fun `con root bypassPermissions pasa a preguntar`() {
        val command = ClaudeAgentCommand.persistent(
            "/c",
            "s",
            resume = false,
            permissionMode = ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS,
        )
        assertTrue(command.contains("""--permission-mode "$([ "$(id -u)" = 0 ] && echo default || echo bypassPermissions)""""))
    }

    @Test
    fun `el token va por stdin y nunca en la linea de comandos`() {
        val command = ClaudeAgentCommand.build("/usr/bin/claude", "/repo", "s")
        assertTrue(command.contains("env -u ANTHROPIC_API_KEY"))
        assertTrue(command.contains("IFS= read -r ARGOS_OAUTH"))
        assertFalse(command.contains("CLAUDE_CODE_OAUTH_TOKEN='"))
    }

    @Test
    fun `tokenLine quita saltos y espacios para no inyectar un prompt`() {
        assertEquals("abcPROMPT\n", String(ClaudeAgentCommand.tokenLine(" abc\nPROMPT ")))
        assertEquals("\n", String(ClaudeAgentCommand.tokenLine(null)))
    }

    @Test
    fun `entrecomilla cwd y binario contra inyeccion de shell`() {
        val command = ClaudeAgentCommand.build("/opt/claude", "/tmp/a b; rm -rf ~", "s")
        assertTrue(command.contains("cd '/tmp/a b; rm -rf ~'"))
        assertFalse(command.contains("&& rm -rf"))
    }

    @Test
    fun `meta conserva el modo y un modo ausente o desconocido pregunta`() {
        val now = java.time.Instant.parse("2026-01-02T03:04:05Z")
        val meta = PersistentAgentMeta("/r", "t", now, "plan")
        assertEquals(meta, PersistentAgentMeta.decode(PersistentAgentMeta.encode(meta)))
        assertEquals(ClaudeAgentCommand.PermissionMode.PLAN, meta.resolvedPermissionMode)
        assertEquals(ClaudeAgentCommand.PermissionMode.DEFAULT, meta.copy(permissionMode = null).resolvedPermissionMode)
        assertEquals(ClaudeAgentCommand.PermissionMode.DEFAULT, meta.copy(permissionMode = "futuro").resolvedPermissionMode)
        assertFalse(PersistentAgentMeta.encode(meta.copy(permissionMode = null)).contains("permissionMode"))
    }

    @Test
    fun `reanudar pide confirmacion solo en los modos que actuan sin preguntar`() {
        val meta = PersistentAgentMeta("/r", "t", java.time.Instant.EPOCH)
        assertFalse(meta.resumeRequiresConfirmation)
        ClaudeAgentCommand.PermissionMode.entries.forEach { mode ->
            assertEquals(
                mode == ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS || mode == ClaudeAgentCommand.PermissionMode.ACCEPT_EDITS,
                meta.copy(permissionMode = mode.rawValue).resumeRequiresConfirmation,
            )
        }
    }

    @Test
    fun `preferencias - proyecto gana a global y global al fallback`() {
        val server = "ABC"
        val key = AgentPermissionPreferences.projectKey(server, "/r.x")
        assertEquals("agentPermissionMode:ABC:L3IueA==", key)
        val modes = mutableMapOf<String, String>()
        fun effective() = AgentPermissionPreferences.effectiveMode(server, "/r.x") { modes[it] }
        assertEquals(ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS, effective())
        modes[AgentPermissionPreferences.GLOBAL_KEY] = "plan"
        assertEquals(ClaudeAgentCommand.PermissionMode.PLAN, effective())
        modes[key] = AgentPermissionPreferences.USE_GLOBAL_CHOICE
        assertEquals(ClaudeAgentCommand.PermissionMode.PLAN, effective())
        modes[key] = "default"
        assertEquals(ClaudeAgentCommand.PermissionMode.DEFAULT, effective())
    }

    @Test
    fun `expande la tilde a HOME en vez de dejarla entre comillas`() {
        assertEquals("\"\$HOME\"", ClaudeAgentCommand.cdTarget("~"))
        assertEquals("\"\$HOME\"/'mi proyecto'", ClaudeAgentCommand.cdTarget("~/mi proyecto"))
        assertEquals("'/abs/path'", ClaudeAgentCommand.cdTarget("/abs/path"))
        assertEquals("\"\$HOME\"", ClaudeAgentCommand.cdTarget(""))
    }

    @Test
    fun `build con directorio tilde usa HOME`() {
        val command = ClaudeAgentCommand.build("/c", "~", "s")
        assertTrue(command.contains("cd \"\$HOME\" &&"))
        assertFalse(command.contains("cd '~'"))
    }

    @Test
    fun `el modo de permisos se refleja en la bandera`() {
        val command = ClaudeAgentCommand.build("/c", "/r", "s", ClaudeAgentCommand.PermissionMode.ACCEPT_EDITS)
        assertTrue(command.contains("--permission-mode acceptEdits"))
    }

    @Test
    fun `el comando anuncia el PID antes del exec`() {
        val command = ClaudeAgentCommand.build("/u/bin/claude", "~/p", "s")
        assertTrue(command.contains("argos_pid"))
        assertTrue(command.contains("exec env -u ANTHROPIC_API_KEY"))
        assertTrue(command.indexOf("argos_pid") < command.indexOf("exec env"))
    }

    @Test
    fun `lee el PID anunciado y rechaza lineas ajenas o PIDs invalidos`() {
        assertEquals(361972, ClaudeAgentCommand.announcedPID("""{"type":"argos_pid","pid":361972}"""))
        assertNull(ClaudeAgentCommand.announcedPID("""{"type":"system","subtype":"init"}"""))
        assertNull(ClaudeAgentCommand.announcedPID("""{"type":"argos_pid","pid":1}"""))
        assertNull(ClaudeAgentCommand.announcedPID("""{"type":"argos_pid","pid":"x"}"""))
        assertNull(ClaudeAgentCommand.announcedPID("texto argos_pid suelto"))
    }

    // AgentAuthParsingTests

    @Test
    fun `extrae el objeto JSON aunque haya ruido alrededor`() {
        val noisy = "Welcome to Ubuntu\n{\"loggedIn\":true,\"subscriptionType\":\"max\"}\nbye"
        assertEquals("{\"loggedIn\":true,\"subscriptionType\":\"max\"}", AgentExecCommands.extractJSONObject(noisy))
    }

    @Test
    fun `JSON limpio se devuelve igual`() {
        val clean = "{\"loggedIn\":false}"
        assertEquals(clean, AgentExecCommands.extractJSONObject(clean))
    }

    @Test
    fun `sin objeto JSON devuelve null`() {
        for (text in listOf("", "no hay json", "}{ invertido")) assertNull(AgentExecCommands.extractJSONObject(text))
    }

    @Test
    fun `el estado de auth tolera ruido y campos ausentes`() {
        val status = AgentExecCommands.parseAuthStatus("motd\n{\"loggedIn\":true,\"subscriptionType\":\"max\",\"email\":null}\n")
        assertEquals(ClaudeAuthStatus(true, "max", null), status)
        assertTrue(status.usesSubscription)
        assertEquals(ClaudeAuthStatus(false, null, null), AgentExecCommands.parseAuthStatus("{\"email\":\"a@b.c\",\"loggedIn\":\"si\"}"))
        assertEquals(ClaudeAuthStatus(false, null, null), AgentExecCommands.parseAuthStatus("error"))
    }

    @Test
    fun `localizar claude toma la ultima ruta absoluta`() {
        assertEquals("/home/u/.local/bin/claude", AgentExecCommands.parseLocateClaude("Bienvenido\n  /home/u/.local/bin/claude  \n"))
        assertNull(AgentExecCommands.parseLocateClaude("sin ruta\n"))
    }

    @Test
    fun `lista subcarpetas tras el pwd, sin barra final y ordenadas sin distinguir mayusculas`() {
        val listing = AgentExecCommands.parseRemoteDirectories("motd /no\n/home/u\nzeta/\nAlfa/\nbeta/\n")
        assertEquals(RemoteDirectoryListing("/home/u", listOf("Alfa", "beta", "zeta")), listing)
        assertNull(AgentExecCommands.parseRemoteDirectories("cd: no existe"))
    }
}
