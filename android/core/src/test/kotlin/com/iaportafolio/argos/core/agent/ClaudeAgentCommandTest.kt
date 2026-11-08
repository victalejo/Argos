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
            oauthToken = "tok",
            sessionID = "11111111-1111-1111-1111-111111111111",
        )
        assertTrue(command.contains("--input-format stream-json"))
        assertTrue(command.contains("--output-format stream-json"))
        assertTrue(command.contains("--permission-prompt-tool stdio"))
        assertTrue(command.contains("--permission-mode bypassPermissions"))
        assertTrue(command.contains("--session-id 11111111-1111-1111-1111-111111111111"))
    }

    @Test
    fun `neutraliza ANTHROPIC_API_KEY e inyecta el token de suscripcion`() {
        val command = ClaudeAgentCommand.build("/usr/bin/claude", "/repo", "secreto", "s")
        assertTrue(command.contains("env -u ANTHROPIC_API_KEY"))
        assertTrue(command.contains("CLAUDE_CODE_OAUTH_TOKEN='secreto'"))
    }

    @Test
    fun `entrecomilla cwd, token y binario contra inyeccion de shell`() {
        val command = ClaudeAgentCommand.build("/opt/claude", "/tmp/a b; rm -rf ~", "x'; echo hi", "s")
        assertTrue(command.contains("cd '/tmp/a b; rm -rf ~'"))
        assertTrue(command.contains("""CLAUDE_CODE_OAUTH_TOKEN='x'\''; echo hi'"""))
        assertFalse(command.contains("&& rm -rf"))
    }

    @Test
    fun `sin token usa el login del servidor y nunca la API`() {
        val command = ClaudeAgentCommand.build("/usr/bin/claude", "/repo", null, "s")
        assertTrue(command.contains("env -u ANTHROPIC_API_KEY"))
        assertFalse(command.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    @Test
    fun `token vacio se trata como ausente`() {
        assertFalse(ClaudeAgentCommand.build("/c", "/r", "", "s").contains("CLAUDE_CODE_OAUTH_TOKEN"))
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
        val command = ClaudeAgentCommand.build("/c", "~", null, "s")
        assertTrue(command.contains("cd \"\$HOME\" &&"))
        assertFalse(command.contains("cd '~'"))
    }

    @Test
    fun `el modo de permisos se refleja en la bandera`() {
        val command = ClaudeAgentCommand.build("/c", "/r", "t", "s", ClaudeAgentCommand.PermissionMode.ACCEPT_EDITS)
        assertTrue(command.contains("--permission-mode acceptEdits"))
    }

    @Test
    fun `el comando anuncia el PID antes del exec`() {
        val command = ClaudeAgentCommand.build("/u/bin/claude", "~/p", null, "s")
        assertTrue(command.contains("argos_pid"))
        assertTrue(command.contains("&& exec env -u ANTHROPIC_API_KEY"))
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
