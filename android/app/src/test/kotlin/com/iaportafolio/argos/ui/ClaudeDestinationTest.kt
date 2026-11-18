package com.iaportafolio.argos.ui

import com.iaportafolio.argos.background.ClaudeTarget
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.ui.navigation.ClaudeDestination
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals

class ClaudeDestinationTest {

    private val web = Project(id = "6F1C2A3B-0000-4000-8000-000000000001", name = "web", group = "ia", path = "/srv/web")

    @Test
    fun `la sesion de un proyecto abre el proyecto y si no la sesion suelta`() {
        assertEquals(
            ClaudeDestination.ProjectTerminal("A", web.id),
            ClaudeDestination.of(ClaudeTarget("A", "ia/web", 2), listOf(web)),
        )
        assertEquals(
            ClaudeDestination.LooseSession("A", "suelta"),
            ClaudeDestination.of(ClaudeTarget("A", "suelta", 0), listOf(web)),
        )
        assertEquals(ClaudeDestination.LooseSession("A", "web"), ClaudeDestination.of(ClaudeTarget("A", "web", 1), listOf(web)))
    }
}
