package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.agent.AgentPermissionPreferences
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand.PermissionMode
import com.iaportafolio.argos.testing.InMemoryAgentPermissionBackend
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class AgentPermissionStoreTest {

    private val backend = InMemoryAgentPermissionBackend()
    private val store = AgentPermissionStore(backend)
    private val projectKey = AgentPermissionPreferences.projectKey("S1", "/srv/api.v2")

    @Test
    fun `sin nada guardado el modo es todos los permisos`() {
        assertEquals(PermissionMode.BYPASS_PERMISSIONS, store.globalMode())
        assertEquals(PermissionMode.BYPASS_PERMISSIONS, store.effectiveMode("S1", "/srv/api.v2"))
    }

    @Test
    fun `guarda con las claves de Apple y sobrevive a reabrir la app`() {
        store.setGlobalMode(PermissionMode.PLAN)
        store.setProjectChoice("S1", "/srv/api.v2", PermissionMode.ACCEPT_EDITS)
        assertEquals(mapOf(AgentPermissionPreferences.GLOBAL_KEY to "plan", projectKey to "acceptEdits"), backend.saved)

        val reopened = AgentPermissionStore(backend)
        assertEquals(PermissionMode.PLAN, reopened.globalMode())
        assertEquals(PermissionMode.ACCEPT_EDITS, reopened.effectiveMode("S1", "/srv/api.v2"))
    }

    @Test
    fun `la elección es por servidor y carpeta`() {
        store.setProjectChoice("S1", "/srv/api.v2", PermissionMode.DEFAULT)
        assertEquals(PermissionMode.BYPASS_PERMISSIONS, store.effectiveMode("S2", "/srv/api.v2"))
        assertEquals(PermissionMode.BYPASS_PERMISSIONS, store.effectiveMode("S1", "/srv/otro"))
    }

    @Test
    fun `volver al ajuste global borra la elección del proyecto`() {
        store.setGlobalMode(PermissionMode.PLAN)
        store.setProjectChoice("S1", "/srv/api.v2", PermissionMode.DEFAULT)
        store.setProjectChoice("S1", "/srv/api.v2", null)
        assertFalse(projectKey in backend.saved)
        assertNull(store.selection("S1", "/srv/api.v2").choice)
        assertEquals(PermissionMode.PLAN, store.effectiveMode("S1", "/srv/api.v2"))
    }

    @Test
    fun `la elección vacía sigue el ajuste global`() {
        val odd = AgentPermissionStore(
            InMemoryAgentPermissionBackend(
                mapOf(AgentPermissionPreferences.GLOBAL_KEY to "default", projectKey to AgentPermissionPreferences.USE_GLOBAL_CHOICE),
            ),
        )
        assertNull(odd.selection("S1", "/srv/api.v2").choice)
        assertEquals(PermissionMode.DEFAULT, odd.effectiveMode("S1", "/srv/api.v2"))
    }

    @Test
    fun `una elección desconocida se muestra como el modo con el que arrancaría`() {
        val odd = AgentPermissionStore(
            InMemoryAgentPermissionBackend(
                mapOf(AgentPermissionPreferences.GLOBAL_KEY to "bypassPermissions", projectKey to "modo-futuro"),
            ),
        )
        val selection = odd.selection("S1", "/srv/api.v2")
        assertEquals(PermissionMode.DEFAULT, selection.effective)
        assertEquals(PermissionMode.DEFAULT, odd.effectiveMode("S1", "/srv/api.v2"))
    }
}
