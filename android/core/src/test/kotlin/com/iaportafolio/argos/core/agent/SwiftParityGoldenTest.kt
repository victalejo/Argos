package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.core.status.ClaudeHookInstaller
import com.iaportafolio.argos.core.status.ClaudeStatusCommands
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * Paridad BYTE A BYTE con Swift. Los ficheros de `swift-golden/` los generó el código Swift
 * real de `ArgosCore/` (Swift 6.4, macOS) con exactamente estas entradas: si un comando,
 * script o JSON de Android diverge en un solo byte, este test falla.
 */
class SwiftParityGoldenTest {

    private val id = "6a55640d-ac70-41ab-8426-6eb72d4fb5eb"
    private val meta = PersistentAgentMeta("~/proyectos/tienda", "tienda \"ñ\" a/b", Instant.ofEpochMilli(1_800_000_000_750))

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)

    private fun assertGolden(name: String, actual: String) = assertEquals(golden(name), actual, "difiere de Swift: $name")

    @Test
    fun `mensajes stream-json`() {
        assertGolden("user-message", AgentProtocol.encodeUserMessage("hola mundo"))
        assertGolden(
            "user-message-tricky",
            AgentProtocol.encodeUserMessage("a/b \"q\" \\ \n\t\r\b\u000C\u0001\u001F\u007F\u2028 ñ 😀 </script>"),
        )
        val rawInput = """{"z":1,"a":1.50,"n":null,"b":true,"f":false,"arr":[1,2.0,"x/y",[],{}],"e":1e-7,"big":1e20,""" +
            """"neg":-0.5,"pi":3.14159,"third":0.3333333333333333,"obj":{"B":1,"a":2,"_":3,"a10":1,"a9":2,"Á":4}}"""
        val input = Json.parseToJsonElement(rawInput)
        assertGolden("permission-allow", AgentProtocol.encodePermissionResponse("req-9", AgentPermissionDecision.Allow(input)))
        assertGolden("permission-allow-empty", AgentProtocol.encodePermissionResponse("r1", AgentPermissionDecision.Allow(EmptyJsonObject)))
        assertGolden(
            "permission-deny",
            AgentProtocol.encodePermissionResponse("req/9", AgentPermissionDecision.Deny(AgentPermissionDecision.USER_DENIED_MESSAGE)),
        )
    }

    @Test
    fun `comandos de claude`() {
        assertGolden(
            "build-token",
            ClaudeAgentCommand.build("/usr/bin/claude", "~/mi proyecto", "x'; echo hi", "11111111-1111-1111-1111-111111111111"),
        )
        assertGolden(
            "build-notoken",
            ClaudeAgentCommand.build("/opt/c laude", "/tmp/a b; rm -rf ~", null, "s", ClaudeAgentCommand.PermissionMode.ACCEPT_EDITS),
        )
        assertGolden("persistent-new", ClaudeAgentCommand.persistent("/usr/bin/claude", id, resume = false))
        assertGolden(
            "persistent-resume",
            ClaudeAgentCommand.persistent("/usr/bin/claude", id, resume = true, permissionMode = ClaudeAgentCommand.PermissionMode.PLAN),
        )
    }

    @Test
    fun `scripts del agente persistente`() {
        assertGolden("meta-json", PersistentAgentMeta.encode(meta))
        assertGolden("launch", PersistentAgentScript.launch(id, meta, ClaudeAgentCommand.persistent("/usr/bin/claude", id, resume = false)))
        assertGolden("send", PersistentAgentScript.send(id, """{"type":"user","message":{"content":"${'$'}(rm -rf ~) `id` 'hola'"}}"""))
        assertGolden("send-answered", PersistentAgentScript.send(id, "{}", answeredRequestID = "r\"1/x"))
        assertGolden("attach", PersistentAgentScript.attach(id))
        assertGolden("attach-from", PersistentAgentScript.attach(id, fromByte = 2048))
        assertGolden("stop", PersistentAgentScript.stop(id, delete = false))
        assertGolden("stop-delete", PersistentAgentScript.stop(id, delete = true))
        assertGolden("list", PersistentAgentScript.list())
        assertGolden("snapshots", PersistentAgentScript.snapshots())
    }

    @Test
    fun `comandos del canal exec`() {
        assertGolden("locate-claude", AgentExecCommands.LOCATE_CLAUDE_SCRIPT)
        assertGolden("kill-agent", AgentExecCommands.killAgentProcess(4242))
        assertGolden("mem-available", AgentExecCommands.AVAILABLE_MEMORY_COMMAND)
        assertGolden("list-dirs", AgentExecCommands.listRemoteDirectories("~/mi repo"))
        assertGolden("dir-exists", AgentExecCommands.remoteDirectoryExists("~/mi repo"))
        assertGolden("auth-status", AgentExecCommands.claudeAuthStatus("/home/u/.local/bin/claude"))
        assertGolden("claude-activity", ClaudeStatusCommands.CLAUDE_ACTIVITY_COMMAND)
    }

    @Test
    fun `hooks de settings json`() {
        assertGolden("hook-working", ClaudeHookInstaller.command(ClaudeActivity.WORKING))
        assertGolden("hook-clear", ClaudeHookInstaller.command(null))
        assertGolden("hooks-empty", ClaudeHookInstaller.serialize(ClaudeHookInstaller.installing(JsonObject(emptyMap()))))
        val existing = """{"model":"opus","env":{},"arr":[],"x":0.1,"y":1.0,"t":true,"u":"a/b\u0001\u2028",""" +
            """"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 transcribe.py"}]}],""" +
            """"Stop":[{"matcher":"","hooks":[{"type":"command","command":"x # argos-claude-status"},""" +
            """{"type":"command","command":"mine"}]}]}}"""
        val settings = ClaudeHookInstaller.parseSettings(existing)
        assertGolden("hooks-merged", ClaudeHookInstaller.serialize(ClaudeHookInstaller.installing(settings)))
        assertGolden("hooks-removed", ClaudeHookInstaller.serialize(ClaudeHookInstaller.removing(settings)))
        assertGolden("serialize-empty", ClaudeHookInstaller.serialize(JsonObject(emptyMap())))
    }

    @Test
    fun `cuerpo del aviso cortado por grafemas`() {
        val body = AgentAttention.Finished("👍🏽".repeat(200), false).notification("t")?.body
        assertGolden("notification-body", assertNotNull(body))
    }
}
