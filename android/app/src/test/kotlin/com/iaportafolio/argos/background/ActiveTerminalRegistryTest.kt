package com.iaportafolio.argos.background

import com.iaportafolio.argos.testing.FakeKeepAliveHost
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ActiveTerminalRegistryTest {

    private class Terminal : ActiveTerminal {
        var disconnected = 0
        var lost = 0
        override fun disconnectFromBackground() {
            disconnected++
        }

        override fun onKeepAliveLost() {
            lost++
        }
    }

    private val host = FakeKeepAliveHost()
    private var enabled = true
    private val registry = ActiveTerminalRegistry(host) { enabled }

    @Test
    fun `arranca el servicio con el primer terminal y no con los siguientes`() {
        registry.register(Terminal())
        registry.register(Terminal())
        assertEquals(1, host.starts)
        assertEquals(2, registry.count.value)
        assertTrue(registry.keepsAliveInBackground)
    }

    @Test
    fun `registrar el mismo terminal dos veces cuenta uno`() {
        val terminal = Terminal()
        registry.register(terminal)
        registry.register(terminal)
        assertEquals(1, registry.count.value)
        assertEquals(1, host.starts)
    }

    @Test
    fun `al cerrarse el último la cuenta llega a cero y un terminal nuevo lo arranca otra vez`() {
        val first = Terminal()
        registry.register(first)
        registry.unregister(first)
        assertEquals(0, registry.count.value)
        assertFalse(registry.keepsAliveInBackground)

        registry.register(Terminal())
        assertEquals(2, host.starts)
    }

    @Test
    fun `con otro terminal aún adjunto sigue activo`() {
        val first = Terminal()
        registry.register(first)
        registry.register(Terminal())
        registry.unregister(first)
        assertEquals(1, registry.count.value)
        assertTrue(registry.keepsAliveInBackground)
    }

    @Test
    fun `con el ajuste desactivado no arranca el servicio pero cuenta el terminal`() {
        enabled = false
        registry.register(Terminal())
        assertEquals(0, host.starts)
        assertEquals(1, registry.count.value)
        assertFalse(registry.keepsAliveInBackground)
    }

    @Test
    fun `desactivar el ajuste con el servicio en marcha deja de mantenerlo vivo`() {
        registry.register(Terminal())
        enabled = false
        assertFalse(registry.keepsAliveInBackground)
    }

    @Test
    fun `si el sistema no deja arrancarlo degrada y lo reintenta al registrar de nuevo`() {
        host.allowed = false
        val terminal = Terminal()
        registry.register(terminal)
        assertFalse(registry.keepsAliveInBackground)

        host.allowed = true
        registry.register(terminal)
        assertEquals(2, host.starts)
        assertTrue(registry.keepsAliveInBackground)
    }

    @Test
    fun `desconectar todo avisa a cada terminal`() {
        val terminals = listOf(Terminal(), Terminal())
        terminals.forEach(registry::register)
        registry.disconnectAll()
        assertEquals(listOf(1, 1), terminals.map { it.disconnected })
    }

    @Test
    fun `desconectar todo admite que cada terminal se quite mientras se recorre`() {
        val leaving = object : ActiveTerminal {
            override fun disconnectFromBackground() = registry.unregister(this)
            override fun onKeepAliveLost() = Unit
        }
        registry.register(leaving)
        registry.register(Terminal())
        registry.disconnectAll()
        assertEquals(1, registry.count.value)
    }

    @Test
    fun `si cae el servicio avisa a los terminales y deja de mantenerlos vivos`() {
        val terminal = Terminal()
        registry.register(terminal)
        registry.serviceLost()
        assertEquals(1, terminal.lost)
        assertFalse(registry.keepsAliveInBackground)
    }
}
