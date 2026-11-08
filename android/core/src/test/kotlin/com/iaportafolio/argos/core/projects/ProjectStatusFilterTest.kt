package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.SessionConnectionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Filtro de proyectos por estado (port de `ProjectStatusFilterTests.swift`). */
class ProjectStatusFilterTest {

    @Test
    fun `cada estado de conexion cae en una sola categoria`() {
        assertEquals(ProjectStatus.STOPPED, ProjectStatus.of(null, onMac = false))
        assertEquals(ProjectStatus.OPEN, ProjectStatus.of(SessionConnectionState.LIVE, onMac = false))
        assertEquals(ProjectStatus.OPEN, ProjectStatus.of(SessionConnectionState.CONNECTING, onMac = false))
        assertEquals(ProjectStatus.OPEN, ProjectStatus.of(SessionConnectionState.ERROR, onMac = false))
        assertEquals(ProjectStatus.BACKGROUND, ProjectStatus.of(SessionConnectionState.ATTACHED_ELSEWHERE, onMac = false))
        assertEquals(ProjectStatus.DORMANT, ProjectStatus.of(SessionConnectionState.DORMANT, onMac = false))
    }

    @Test
    fun `enviado al Mac tiene prioridad aunque quede sesion en el servidor`() {
        assertEquals(ProjectStatus.ON_MAC, ProjectStatus.of(null, onMac = true))
        assertEquals(ProjectStatus.ON_MAC, ProjectStatus.of(SessionConnectionState.DORMANT, onMac = true))
        assertEquals(ProjectStatus.ON_MAC, ProjectStatus.of(SessionConnectionState.LIVE, onMac = true))
    }

    @Test
    fun `Todos incluye todo y cada filtro solo su estado`() {
        val all = ProjectStatus.entries
        assertTrue(all.all(ProjectStatusFilter.ALL::includes))
        assertEquals(listOf(ProjectStatus.OPEN), all.filter(ProjectStatusFilter.OPEN::includes))
        assertEquals(listOf(ProjectStatus.DORMANT), all.filter(ProjectStatusFilter.DORMANT::includes))
        assertEquals(listOf(ProjectStatus.STOPPED), all.filter(ProjectStatusFilter.STOPPED::includes))
        assertEquals(listOf(ProjectStatus.ON_MAC), all.filter(ProjectStatusFilter.ON_MAC::includes))
        assertEquals(listOf(ProjectStatus.BACKGROUND), all.filter(ProjectStatusFilter.BACKGROUND::includes))
    }

    @Test
    fun `todas las opciones tienen titulo y ayuda, con el rawValue y orden de Apple`() {
        ProjectStatusFilter.entries.forEach {
            assertTrue(it.title.isNotEmpty())
            assertTrue(it.help.isNotEmpty())
            assertEquals(it, ProjectStatusFilter.fromId(it.id))
        }
        assertEquals(listOf("all", "open", "dormant", "stopped", "onMac", "background"), ProjectStatusFilter.entries.map { it.id })
    }
}
