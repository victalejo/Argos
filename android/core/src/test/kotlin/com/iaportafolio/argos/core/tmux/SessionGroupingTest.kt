package com.iaportafolio.argos.core.tmux

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/SessionGroupingTests.swift`. */
class SessionGroupingTest {

    private fun session(name: String) = TmuxSession(name, windowCount = 1, isAttached = false, createdAt = Instant.EPOCH)

    @Test
    fun `split separa por la primera barra`() {
        assertEquals(SessionGrouping.Parts("magic-agents", "backend"), SessionGrouping.split("magic-agents/backend"))
    }

    @Test
    fun `sin barra va al grupo General con el nombre completo`() {
        assertEquals(SessionGrouping.Parts("General", "main"), SessionGrouping.split("main"))
    }

    @Test
    fun `prefijo vacio va a General con el nombre completo`() {
        assertEquals(SessionGrouping.Parts("General", "/foo"), SessionGrouping.split("/foo"))
    }

    @Test
    fun `sufijo vacio usa el grupo y el nombre completo`() {
        assertEquals(SessionGrouping.Parts("foo", "foo/"), SessionGrouping.split("foo/"))
    }

    @Test
    fun `General siempre va al final`() {
        val groups = SessionGrouping.groups(listOf(session("zeta/a"), session("solo"), session("alpha/b")))
        assertEquals(listOf("alpha", "zeta", "General"), groups.map { it.name })
    }

    @Test
    fun `orden interno por nombre corto sin distinguir mayusculas`() {
        val groups = SessionGrouping.groups(listOf(session("g/Charlie"), session("g/alpha"), session("g/Bravo")))
        val g = assertNotNull(groups.firstOrNull { it.name == "g" })
        assertEquals(listOf("g/alpha", "g/Bravo", "g/Charlie"), g.sessions.map { it.name })
    }

    @Test
    fun `lista vacia produce cero grupos`() {
        assertTrue(SessionGrouping.groups(emptyList()).isEmpty())
    }
}
