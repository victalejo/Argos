package com.iaportafolio.argos.core

import net.schmizz.sshj.fake.ConnectionException
import net.schmizz.sshj.fake.OpenFailException
import net.schmizz.sshj.fake.SFTPException
import net.schmizz.sshj.fake.TransportException
import net.schmizz.sshj.fake.UserAuthException
import java.io.IOException
import java.net.ConnectException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeoutException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Los errores de sshj y de red que llegan sin traducir se explican en español (como `SSHErrorMessageTests.swift`). */
class ErrorMessageTest {

    private fun assertStarts(prefix: String, error: Throwable) {
        val text = error.userMessage
        assertTrue(text.startsWith(prefix), "«$text» debería empezar por «$prefix»")
    }

    @Test
    fun `canal rechazado sugiere demasiados canales y reintentar`() {
        val text = OpenFailException("Opening `session` channel failed: open failed").userMessage
        assertTrue(text.contains("rechazó abrir un canal"))
        assertTrue(text.contains("Reintenta"))
        assertTrue(text.contains("open failed"), "conserva el detalle real")
    }

    @Test
    fun `autenticacion timeout inaccesible y conexion cortada`() {
        assertStarts(TransportErrorText.AUTHENTICATION, UserAuthException("Exhausted available authentication methods"))
        assertStarts(
            TransportErrorText.TIMEOUT,
            ConnectionException("x", TimeoutException("Timeout expired: 30000 MILLISECONDS")),
        )
        assertStarts(TransportErrorText.TIMEOUT, ConnectionException("Timeout expired: 30000 MILLISECONDS"))
        assertStarts(TransportErrorText.TIMEOUT, SocketTimeoutException("connect timed out"))
        assertStarts(TransportErrorText.UNREACHABLE, ConnectException("Connection refused"))
        assertStarts(TransportErrorText.CONNECTION_CLOSED, TransportException("Broken transport; encountered EOF"))
        assertStarts(TransportErrorText.CONNECTION_CLOSED, SocketException("Connection reset"))
    }

    @Test
    fun `sftp sin permiso o sin archivo`() {
        assertStarts(TransportErrorText.SFTP_PERMISSION, SFTPException("Permission denied"))
        assertStarts(TransportErrorText.SFTP_NOT_FOUND, SFTPException("No such file"))
    }

    @Test
    fun `los errores propios y los IOException con texto se dejan tal cual`() {
        assertEquals("sin red", IOException("sin red").userMessage)
        assertEquals("Timeout expired", IOException("Timeout expired").userMessage)
        assertEquals("Falló algo", IllegalStateException("Falló algo").userMessage)
        assertEquals("Failure", SFTPException("Failure").userMessage, "sin clasificar: el texto original")
    }
}
