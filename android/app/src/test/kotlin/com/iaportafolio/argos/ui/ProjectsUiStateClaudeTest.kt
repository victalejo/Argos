package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.status.ClaudeActivity
import com.iaportafolio.argos.core.status.ClaudeActivitySnapshot
import com.iaportafolio.argos.testing.session
import com.iaportafolio.argos.ui.projects.ProjectsUiState
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** Búsqueda e insignias de Claude derivadas del estado de la lista de proyectos. */
class ProjectsUiStateClaudeTest {

    private val web = Project(id = "6F1C2A3B-0000-4000-8000-000000000001", name = "web", group = "ia", path = "/srv/web")
    private val api = Project(id = "6F1C2A3B-0000-4000-8000-000000000002", name = "api", group = "ia", path = "/srv/api")

    private fun state(query: String = "") = ProjectsUiState(
        serverId = "A",
        projects = listOf(web, api),
        sessions = listOf(session("ia/web"), session("suelta")),
        claudeActivity = ClaudeActivitySnapshot.fromListPanes("-|waiting|%1|1|ia/web\n-|done|%2|1|suelta"),
        query = query,
    )

    @Test
    fun `insignia por proyecto, por sesion suelta y por grupo`() {
        val state = state()
        val section = state.sections.single()
        assertEquals(ClaudeActivity.WAITING, state.claude(section.entries.first { it.project.name == "web" }))
        assertEquals(null, state.claude(section.entries.first { it.project.name == "api" }))
        assertEquals(ClaudeActivity.WAITING, state.claude(section))
        assertEquals(ClaudeActivity.DONE, state.claude(state.looseSessions.single()))
    }

    @Test
    fun `la busqueda filtra proyectos y sesiones y abre los grupos`() {
        val state = state(query = "WEB")
        assertEquals(listOf("web"), state.sections.flatMap { it.entries }.map { it.project.name })
        assertFalse(state.sections.single().isCollapsed)
        assertEquals(emptyList(), state.looseSessions)
        assertEquals(listOf("suelta"), state(query = "suel").looseSessions.map { it.name })
    }
}
