package com.iaportafolio.argos.core

import com.iaportafolio.argos.core.tmux.TmuxCommands
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Port de `TerminalAttachTests.swift`: comando de attach y detección de sesión inexistente. */
class TerminalAttachTest {

    private fun feed(vararg chunks: String): TerminalAttachMonitor =
        TerminalAttachMonitor().also { monitor -> chunks.forEach { monitor.consume(it.toByteArray(Charsets.UTF_8)) } }

    @Test
    fun `attach usa target exacto entrecomillado`() {
        assertEquals("tmux -u attach -t '=tmh/web'", TmuxCommands.attach("tmh/web"))
        assertEquals("tmux -u attach -t '=it'\\''s'", TmuxCommands.attach("it's"))
    }

    @Test
    fun `reconoce cada mensaje de sesion inexistente de tmux`() {
        listOf(
            "can't find session: tmh/web\r\n",
            "session not found: tmh/web\r\n",
            "no server running on /tmp/tmux-1000/default\r\n",
            "no sessions\r\n",
        ).forEach { message ->
            val monitor = feed(message)
            assertTrue(monitor.sawMissingSession, message)
            assertFalse(monitor.isAttached, message)
        }
    }

    @Test
    fun `no distingue mayusculas`() {
        assertTrue(feed("Can't Find Session: web").sawMissingSession)
    }

    @Test
    fun `mensaje partido en dos trozos se reconoce`() {
        assertTrue(feed("can't fi", "nd session: tmh/web\r\n").sawMissingSession)
        assertTrue(feed("bienvenido\r\nno serv", "er running on /tmp/x").sawMissingSession)
    }

    @Test
    fun `tras entrar en la pantalla alternativa lo de dentro no cuenta`() {
        val monitor = feed("\u001B[?1049h\u001B[H", "$ tmux attach -t x\r\ncan't find session: x\r\n")
        assertTrue(monitor.isAttached)
        assertFalse(monitor.sawMissingSession)
    }

    @Test
    fun `MOTD normal no dispara`() {
        val monitor = feed(
            "Welcome to Ubuntu 24.04 LTS\r\n * Documentation:  https://help.ubuntu.com\r\n",
            "Last login: Sat Nov 22 10:00:00 2026 from 10.0.0.2\r\n",
        )
        assertFalse(monitor.sawMissingSession)
        assertFalse(monitor.isAttached)
    }

    @Test
    fun `tras ver sesion inexistente deja de mirar`() {
        val monitor = feed("no sessions\r\n", "\u001B[?1049h")
        assertTrue(monitor.sawMissingSession)
        assertFalse(monitor.isAttached)
    }

    @Test
    fun `mensaje del error en espanol`() {
        val error = TerminalSessionMissingError("tmh/web")
        assertEquals("La sesión «tmh/web» ya no existe en el servidor.", error.message)
        assertEquals(TerminalSessionMissingError("tmh/web"), error)
    }

    // MARK: - TerminalAttach.monitoring

    private fun emit(text: String): suspend (suspend (ByteArray) -> Unit) -> Unit =
        { output -> output(text.toByteArray(Charsets.UTF_8)) }

    @Test
    fun `PTY que termina tras sesion inexistente lanza TerminalSessionMissingError`() = runBlocking {
        val seen = StringBuilder()
        val error = assertFailsWith<TerminalSessionMissingError> {
            TerminalAttach.monitoring("web", { seen.append(String(it, Charsets.UTF_8)) }, emit("can't find session: =web\r\n"))
        }
        assertEquals("web", error.session)
        // La salida sigue llegando a la UI.
        assertEquals("can't find session: =web\r\n", seen.toString())
    }

    @Test
    fun `PTY que falla tras sesion inexistente lanza el error tipado en lugar del original`() = runBlocking {
        val original = IOException("canal cerrado")
        val error = assertFailsWith<TerminalSessionMissingError> {
            TerminalAttach.monitoring("web", {}) { output ->
                output("no sessions\r\n".toByteArray())
                throw original
            }
        }
        assertSame(original, error.cause)
    }

    @Test
    fun `sin mensaje de tmux se conserva el resultado o el error original`() = runBlocking {
        TerminalAttach.monitoring("web", {}, emit("\u001B[?1049hcan't find session"))
        val original = IOException("red")
        assertSame(original, assertFailsWith<IOException> { TerminalAttach.monitoring("web", {}) { throw original } })
    }

    @Test
    fun `la cancelacion se propaga tal cual`() = runBlocking {
        assertFailsWith<CancellationException> {
            TerminalAttach.monitoring("web", {}) { output ->
                output("no sessions".toByteArray())
                throw CancellationException("detach")
            }
        }
        Unit
    }
}
