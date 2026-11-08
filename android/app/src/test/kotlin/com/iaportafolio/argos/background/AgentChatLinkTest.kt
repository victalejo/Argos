package com.iaportafolio.argos.background

import com.iaportafolio.argos.testing.AGENT_1
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.server
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AgentChatLinkTest {

    private val servers = InMemoryServerRepository(listOf(server(id = "A")))
    private val action = AgentChatLink.ACTION_OPEN_CHAT

    @Test
    fun `acepta la acción del aviso con servidor existente y UUID`() {
        assertEquals(AgentChatTarget("A", AGENT_1), AgentChatLink.parse(action, "A", AGENT_1, servers))
    }

    @Test
    fun `ignora un servidor que no existe`() {
        assertNull(AgentChatLink.parse(action, "borrado", AGENT_1, servers))
    }

    @Test
    fun `ignora un id que no es un UUID`() {
        listOf("", "x", "$AGENT_1; rm -rf ~", "../../etc", "$AGENT_1\n").forEach {
            assertNull(AgentChatLink.parse(action, "A", it, servers), it)
        }
    }

    @Test
    fun `ignora extras ausentes`() {
        assertNull(AgentChatLink.parse(action, null, AGENT_1, servers))
        assertNull(AgentChatLink.parse(action, "A", null, servers))
    }

    @Test
    fun `ignora otra acción aunque los extras sean válidos`() {
        assertNull(AgentChatLink.parse("android.intent.action.MAIN", "A", AGENT_1, servers))
        assertNull(AgentChatLink.parse(null, "A", AGENT_1, servers))
    }
}
