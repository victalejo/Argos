package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.Server
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Grupos de sesiones colapsables (port de `CollapsedGroupsTests.swift`). La persistencia es de
 * plataforma: aquí se comprueba que el estado se reconstruye desde las claves guardadas.
 */
class CollapsedSessionGroupsTest {

    @Test
    fun `por defecto ningun grupo esta colapsado`() {
        assertFalse(CollapsedSessionGroups().isCollapsed(Server.newId(), "ia-portafolio"))
    }

    @Test
    fun `alternar colapsa y vuelve a expandir`() {
        val server = Server.newId()
        val collapsed = CollapsedSessionGroups().toggled(server, "ia-portafolio")
        assertTrue(collapsed.isCollapsed(server, "ia-portafolio"))
        assertFalse(collapsed.toggled(server, "ia-portafolio").isCollapsed(server, "ia-portafolio"))
    }

    @Test
    fun `el estado es independiente por servidor y por grupo`() {
        val a = Server.newId()
        val b = Server.newId()
        val state = CollapsedSessionGroups().toggled(a, "web")
        assertTrue(state.isCollapsed(a, "web"))
        assertFalse(state.isCollapsed(b, "web"))
        assertFalse(state.isCollapsed(a, "api"))
    }

    @Test
    fun `persiste - se reconstruye desde las claves guardadas con el formato de Apple`() {
        val server = "6f1c2a3b-0000-4000-8000-000000000001"
        val saved = CollapsedSessionGroups().toggled(server, "inducascos").toggled(server, "api").sortedKeys
        assertEquals(
            listOf("6F1C2A3B-0000-4000-8000-000000000001/api", "6F1C2A3B-0000-4000-8000-000000000001/inducascos"),
            saved,
        )
        assertTrue(CollapsedSessionGroups(saved.toSet()).isCollapsed(server, "inducascos"))
    }
}
