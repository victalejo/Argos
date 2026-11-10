package com.iaportafolio.argos.core.ports

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Reenvío de puertos: parser de `ss`/`netstat` (mismos casos que `PortForwardingTests.swift`). */
class PortsTest {

    @Test
    fun `el comando es byte a byte el de Swift`() {
        val golden = assertNotNull(javaClass.getResource("/swift-golden/ports-listening.txt")).readText(Charsets.UTF_8)
        assertEquals(golden, ListeningPortParser.command)
    }

    @Test
    fun `ss -Htlnp funde IPv4 e IPv6 y se queda el proceso`() {
        val output = """
            LISTEN 0      511        0.0.0.0:3000       0.0.0.0:*    users:(("node",pid=812,fd=21))
            LISTEN 0      511           [::]:3000          [::]:*
            LISTEN 0      4096     127.0.0.53%lo:53         0.0.0.0:*
            LISTEN 0      128        0.0.0.0:22         0.0.0.0:*
            LISTEN 0      244      127.0.0.1:5432       0.0.0.0:*
            LISTEN 0      511       10.0.0.5:8080       0.0.0.0:*    users:(("python3",pid=9,fd=3))
        """.trimIndent()
        val ports = ListeningPortParser.parse(output)
        assertEquals(listOf(22, 53, 3000, 5432, 8080), ports.map { it.port })
        val node = ports.first { it.port == 3000 }
        assertEquals("node", node.processName)
        assertEquals("localhost", node.targetHost)
        assertEquals("10.0.0.5", ports.first { it.port == 8080 }.targetHost)
        assertEquals(listOf(3000, 5432, 8080), ports.filter { it.isLikelyDevServer }.map { it.port })
    }

    @Test
    fun `ss sin -H ignora la cabecera`() {
        val output = "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n" +
            "LISTEN 0      511                *:5173            *:*\n"
        assertEquals(listOf(5173), ListeningPortParser.parse(output).map { it.port })
    }

    @Test
    fun `netstat -tln`() {
        val output = """
            Active Internet connections (only servers)
            Proto Recv-Q Send-Q Local Address           Foreign Address         State
            tcp        0      0 127.0.0.1:8000          0.0.0.0:*               LISTEN
            tcp6       0      0 :::4000                 :::*                    LISTEN
            tcp        0      0 10.0.0.2:9000           10.0.0.9:51000          ESTABLISHED
        """.trimIndent()
        val ports = ListeningPortParser.parse(output)
        assertEquals(listOf(4000, 8000), ports.map { it.port })
        assertTrue(ports.all { it.targetHost == "localhost" })
    }

    @Test
    fun `direcciones con corchetes, interfaz y comodin`() {
        assertEquals("::1" to 3000, ListeningPortParser.splitHostPort("[::1]:3000"))
        assertEquals("*" to 80, ListeningPortParser.splitHostPort("*:80"))
        assertEquals("127.0.0.53" to 53, ListeningPortParser.splitHostPort("127.0.0.53%lo:53"))
        assertEquals("::" to 4000, ListeningPortParser.splitHostPort(":::4000"))
        assertNull(ListeningPortParser.splitHostPort("0.0.0.0:0"))
        assertNull(ListeningPortParser.splitHostPort("0.0.0.0:99999"))
        assertNull(ListeningPortParser.splitHostPort("sin-puerto"))
    }

    @Test
    fun `validacion de puertos escritos a mano`() {
        assertEquals(3000, parsePort("3000"))
        assertEquals(80, parsePort(" 80 "))
        assertNull(parsePort("0"))
        assertNull(parsePort("70000"))
        assertNull(parsePort("x"))
    }

    @Test
    fun `url local del tunel`() {
        val forward = ActivePortForward("id", 3000, "localhost", 3001)
        assertEquals("http://localhost:3001", forward.localUrl)
        assertEquals("localhost:3001", forward.localAddress)
    }
}
