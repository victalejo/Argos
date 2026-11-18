package com.iaportafolio.argos.ui.navigation

import com.iaportafolio.argos.background.AgentChatTarget
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.testing.AGENT_1
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AgentNotificationRouteTest {

    private val web = Project(name = "web", path = "/srv/web/")
    private val api = Project(name = "api", path = "/srv/api")

    @Test
    fun `el aviso de un agente abre el proyecto de su carpeta`() {
        assertEquals(web, projectForAgent(AgentChatTarget("A", AGENT_1, "/srv/web"), listOf(api, web)))
        assertEquals(api, projectForAgent(AgentChatTarget("A", AGENT_1, "/srv/api/"), listOf(api, web)))
    }

    @Test
    fun `sin carpeta o sin proyecto se abre el chat directamente`() {
        assertNull(projectForAgent(AgentChatTarget("A", AGENT_1), listOf(api, web)))
        assertNull(projectForAgent(AgentChatTarget("A", AGENT_1, "/srv/otro"), listOf(api, web)))
        assertNull(projectForAgent(AgentChatTarget("A", AGENT_1, "/srv/web/sub"), listOf(api, web)))
    }
}
