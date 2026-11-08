package com.iaportafolio.argos.background

import com.iaportafolio.argos.testing.AGENT_1
import com.iaportafolio.argos.testing.AGENT_2
import com.iaportafolio.argos.testing.InMemoryAgentWatchBackend
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AgentWatchStoreTest {

    private val backend = InMemoryAgentWatchBackend()
    private val store = AgentWatchStore(backend)

    @Test
    fun `los avisos están activados por defecto y el cambio se persiste`() {
        assertTrue(store.notificationsEnabled.value)
        store.setNotificationsEnabled(false)
        assertFalse(AgentWatchStore(backend).notificationsEnabled.value)
    }

    @Test
    fun `servidores y bytes vistos sobreviven a un reinicio`() {
        store.watch("A")
        store.markSeen("A", AGENT_1, 10)
        val reloaded = AgentWatchStore(backend)
        assertEquals(setOf("A"), reloaded.watchedServers())
        assertEquals(mapOf(AGENT_1 to 10L), reloaded.seenBytes("A"))
    }

    @Test
    fun `un estado corrupto se ignora sin caerse`() {
        val corrupt = InMemoryAgentWatchBackend(mapOf("agents.servers" to "{no", "agents.seenBytes" to "[1,2"))
        val reloaded = AgentWatchStore(corrupt)
        assertTrue(reloaded.watchedServers().isEmpty())
        assertTrue(reloaded.seenBytes("A").isEmpty())
    }

    @Test
    fun `sin servidor apuntado no se guarda lo visto`() {
        store.markSeen("A", AGENT_1, 10)
        assertTrue(store.seenBytes("A").isEmpty())
    }

    @Test
    fun `quitar un servidor devuelve sus agentes y olvida lo visto`() {
        store.watch("A")
        store.markSeen("A", AGENT_1, 10)
        assertEquals(setOf(AGENT_1), store.unwatch("A"))
        assertTrue(AgentWatchStore(backend).watchedServers().isEmpty())
        assertTrue(AgentWatchStore(backend).seenBytes("A").isEmpty())
    }

    @Test
    fun `applyCheck conserva lo marcado después y los agentes nuevos`() {
        store.watch("A")
        store.markSeen("A", AGENT_1, 10)
        val before = store.seenBytes("A")
        store.markSeen("A", AGENT_1, 99)
        store.markSeen("A", AGENT_2, 5)

        store.applyCheck("A", before, mapOf(AGENT_1 to 20L))

        assertEquals(mapOf(AGENT_1 to 99L, AGENT_2 to 5L), store.seenBytes("A"))
    }

    @Test
    fun `applyCheck de un servidor quitado entretanto no lo resucita`() {
        store.watch("A")
        store.unwatch("A")
        store.applyCheck("A", emptyMap(), mapOf(AGENT_1 to 20L))
        assertTrue(store.seenBytes("A").isEmpty())
    }
}
