package com.iaportafolio.argos.core

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Paridad con `ConnectionHealthTests` y `LinkLivenessTests` de Swift. */
class ConnectionAdmissionTest {

    @Test
    fun `espera exponencial con tope de 60 s`() {
        assertEquals(listOf(1L, 2, 4, 8, 16, 32, 60, 60), (1..8).map { ConnectionHealth.backoffMillis(it) / 1_000 })
        assertEquals(1_000L, ConnectionHealth.backoffMillis(0))
    }

    @Test
    fun `un fallo de red hace esperar al fondo pero no al usuario`() {
        val failed = ConnectionHealth().recordingFailure(SSHFailureKind.NETWORK, "sin red", nowMillis = 1_000)
        assertEquals(ConnectionHealth.Admission.Allowed, failed.admission(ConnectionPriority.USER, 1_000))
        assertEquals(ConnectionHealth.Admission.Deferred(1_000), failed.admission(ConnectionPriority.BACKGROUND, 1_000))
        assertEquals(ConnectionHealth.Admission.Allowed, failed.admission(ConnectionPriority.BACKGROUND, 2_000))
        val twice = failed.recordingFailure(SSHFailureKind.NETWORK, "sin red", nowMillis = 2_000)
        assertEquals(ConnectionHealth.Status.BackingOff(2, 4_000), twice.status)
        assertEquals(ConnectionHealth(), twice.recordingSuccess())
    }

    @Test
    fun `credenciales o host key bloquean el fondo y un fallo de red no lo levanta`() {
        for (kind in listOf(SSHFailureKind.AUTHENTICATION, SSHFailureKind.HOST_KEY)) {
            val blocked = ConnectionHealth().recordingFailure(kind, "rechazada", 0)
            assertTrue(blocked.isBlocked)
            assertEquals(ConnectionHealth.Admission.Blocked(kind), blocked.admission(ConnectionPriority.BACKGROUND, 999_999))
            assertEquals(ConnectionHealth.Admission.Allowed, blocked.admission(ConnectionPriority.USER, 0))
            assertEquals(blocked, blocked.recordingFailure(SSHFailureKind.NETWORK, "sin red", 5))
        }
    }

    @Test
    fun `un rechazo de canal es respuesta y solo varios sin respuesta seguidos matan`() {
        var liveness = LinkLiveness()
        liveness = liveness.recording(ProbeOutcome.UNRESPONSIVE, threshold = 3)
        liveness = liveness.recording(ProbeOutcome.UNRESPONSIVE, threshold = 3)
        assertFalse(liveness.isDead(3))
        assertEquals(LinkLiveness(), liveness.recording(ProbeOutcome.REJECTED, 3))
        assertTrue(liveness.recording(ProbeOutcome.UNRESPONSIVE, 3).isDead(3))
        assertTrue(LinkLiveness().recording(ProbeOutcome.BROKEN, 3).isDead(3))
        assertEquals(LinkLiveness(), liveness.recording(ProbeOutcome.ALIVE, 3))
    }

    @Test
    fun `la prioridad viaja en el contexto`() = runBlocking {
        assertEquals(ConnectionPriority.USER, ConnectionPriority.current())
        assertEquals(ConnectionPriority.BACKGROUND, ConnectionPriority.background { ConnectionPriority.current() })
        assertIs<SSHBackingOffException>(SSHBackingOffException(2_500, "x"))
        assertTrue(SSHBackingOffException(2_500, "x").message.orEmpty().contains("2 s"))
    }
}
