package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.NotificationRoute
import com.iaportafolio.argos.testing.AGENT_1
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.server
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AgentChatLinkTest {

    private val servers = InMemoryServerRepository(listOf(server(id = "A")))
    private val action = AgentChatLink.ACTION_OPEN_CHAT

    /** Extras con las claves de `NotificationRoute` (las de Swift). */
    private fun parse(action: String?, serverId: String?, agentId: String?, extra: Map<String, Any> = emptyMap()): AgentChatTarget? {
        val extras = buildMap {
            serverId?.let { put(NotificationRoute.SERVER_KEY, it) }
            agentId?.let { put(NotificationRoute.AGENT_KEY, it) }
            putAll(extra)
        }
        return AgentChatLink.parse(action, extras::get, servers)
    }

    @Test
    fun `acepta la acción del aviso con servidor existente y UUID`() {
        assertEquals(AgentChatTarget("A", AGENT_1), parse(action, "A", AGENT_1))
    }

    @Test
    fun `ignora un servidor que no existe`() {
        assertNull(parse(action, "borrado", AGENT_1))
    }

    @Test
    fun `ignora un id que no es un UUID`() {
        listOf("", "x", "$AGENT_1; rm -rf ~", "../../etc", "$AGENT_1\n").forEach {
            assertNull(parse(action, "A", it), it)
        }
    }

    @Test
    fun `ignora extras ausentes`() {
        assertNull(parse(action, null, AGENT_1))
        assertNull(parse(action, "A", null))
    }

    @Test
    fun `ignora otra acción aunque los extras sean válidos`() {
        assertNull(parse("android.intent.action.MAIN", "A", AGENT_1))
        assertNull(parse(null, "A", AGENT_1))
    }

    @Test
    fun `lleva la carpeta del proyecto y descarta una relativa o con control`() {
        val path = mapOf(NotificationRoute.PROJECT_PATH_KEY to "/srv/web")
        assertEquals(AgentChatTarget("A", AGENT_1, "/srv/web"), parse(action, "A", AGENT_1, path))
        assertNull(parse(action, "A", AGENT_1, mapOf(NotificationRoute.PROJECT_PATH_KEY to "~/web"))?.projectPath)
        assertNull(parse(action, "A", AGENT_1, mapOf(NotificationRoute.PROJECT_PATH_KEY to "/srv/\u0000x"))?.projectPath)
    }

    @Test
    fun `entiende los avisos publicados por versiones anteriores`() {
        val legacy = mapOf<String, Any>(
            "com.iaportafolio.argos.extra.SERVER_ID" to "A",
            "com.iaportafolio.argos.extra.AGENT_ID" to AGENT_1,
        )
        assertEquals(AgentChatTarget("A", AGENT_1), AgentChatLink.parse(action, legacy::get, servers))
    }

    @Test
    fun `la ruta escrita es la de Swift y vuelve igual`() {
        val route = AgentChatLink.route("A", AGENT_1, "/srv/web")
        assertEquals(
            mapOf(
                "argos.serverID" to "A", "argos.projectPath" to "/srv/web",
                "argos.tab" to "agent", "argos.agentID" to AGENT_1,
            ),
            route.extras,
        )
        assertEquals(route, NotificationRoute.fromExtras(route.extras::get))
    }
}
