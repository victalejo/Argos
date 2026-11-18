package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.ConnectionPriority
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Paridad con `ChannelGateTests` de Swift: prioridades, cancelación y tope adaptativo. */
class ChannelGateTest {

    @Test
    fun `el fondo usa como mucho la mitad y el usuario pasa delante`() = runBlocking {
        val gate = ChannelGate(4)
        gate.acquire(ConnectionPriority.BACKGROUND)
        gate.acquire(ConnectionPriority.BACKGROUND)
        val third = async(start = CoroutineStart.UNDISPATCHED) { gate.acquire(ConnectionPriority.BACKGROUND) }
        yield()
        assertFalse(third.isCompleted, "el fondo no pasa de la mitad del tope")
        gate.acquire(ConnectionPriority.USER)
        assertEquals(3, gate.activeCount)
        gate.release(ConnectionPriority.BACKGROUND)
        third.await()
        assertEquals(3, gate.activeCount)
    }

    @Test
    fun `esperar es cancelable y no ocupa turno`() = runBlocking {
        val gate = ChannelGate(1)
        gate.acquire(ConnectionPriority.USER)
        val waiting = launch(start = CoroutineStart.UNDISPATCHED) { gate.acquire(ConnectionPriority.USER) }
        waiting.cancel()
        waiting.join()
        gate.release(ConnectionPriority.USER)
        assertEquals(0, gate.activeCount)
    }

    @Test
    fun `el tope baja ante un rechazo hasta 1 y vuelve con la conexion nueva`() = runBlocking {
        val gate = ChannelGate(6)
        repeat(4) { gate.acquire(ConnectionPriority.USER) }
        assertEquals(3, gate.lowerLimitAfterRejection())
        repeat(4) { gate.release(ConnectionPriority.USER) }
        gate.acquire(ConnectionPriority.USER)
        assertEquals(1, gate.lowerLimitAfterRejection()) // MaxSessions 1: suelo en 1
        assertEquals(1, gate.lowerLimitAfterRejection())
        gate.release(ConnectionPriority.USER)
        gate.resetLimit()
        assertEquals(6, gate.currentLimit)
    }

    @Test
    fun `con el tope bajado los que esperan entran al liberar`() = runBlocking {
        val gate = ChannelGate(2)
        gate.acquire(ConnectionPriority.USER)
        gate.acquire(ConnectionPriority.USER)
        gate.lowerLimitAfterRejection()
        val next = async(start = CoroutineStart.UNDISPATCHED) { gate.acquire(ConnectionPriority.USER) }
        gate.release(ConnectionPriority.USER)
        yield()
        assertFalse(next.isCompleted, "con el tope en 1 y uno dentro, espera")
        gate.release(ConnectionPriority.USER)
        next.await()
        assertTrue(gate.activeCount == 1)
    }
}
