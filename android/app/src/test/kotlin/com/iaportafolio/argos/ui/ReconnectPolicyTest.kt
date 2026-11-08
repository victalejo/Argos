package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.HostKeyMismatchException
import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.data.MissingCredentialsException
import com.iaportafolio.argos.ssh.SshConnectionException
import com.iaportafolio.argos.ui.terminal.ReconnectPolicy
import com.iaportafolio.argos.ui.terminal.TerminalServerMissingException
import com.iaportafolio.argos.ui.terminal.TerminalStreamingUnavailableException
import org.junit.jupiter.api.Test
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReconnectPolicyTest {

    private val policy = ReconnectPolicy()

    @Test
    fun `backoff exponencial con tope`() {
        assertEquals(listOf(1_000L, 2_000, 4_000, 8_000, 15_000, 30_000, 30_000), (0..6).map { policy.delayFor(it) })
        assertEquals(1_000L, policy.delayFor(-3))
    }

    @Test
    fun `los fallos de red se reintentan`() {
        assertTrue(policy.isRetryable(IOException("Broken pipe")))
        assertTrue(policy.isRetryable(SshConnectionException.Unreachable("dev:22")))
        assertTrue(policy.isRetryable(SshConnectionException.Timeout("dev:22")))
    }

    @Test
    fun `los fallos que exigen acción no se reintentan, aunque vengan encadenados`() {
        assertFalse(policy.isRetryable(SshConnectionException.AuthenticationFailed("victor")))
        assertFalse(policy.isRetryable(MissingCredentialsException("falta")))
        assertFalse(policy.isRetryable(SSHServiceError.TmuxNotInstalled()))
        assertFalse(policy.isRetryable(TerminalServerMissingException()))
        assertFalse(policy.isRetryable(TerminalStreamingUnavailableException()))
        assertFalse(policy.isRetryable(IOException("envoltorio", HostKeyMismatchException("dev:22", "a", "b"))))
    }
}
