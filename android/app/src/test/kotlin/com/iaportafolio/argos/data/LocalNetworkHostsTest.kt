package com.iaportafolio.argos.data

import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.net.UnknownHostException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LocalNetworkHostsTest {

    @ParameterizedTest
    @ValueSource(
        strings = [
            "10.0.0.5", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.3.4",
            "fe80::1", "fe80::1%wlan0", "[fe80::abcd]", "fd12:3456::1", "fc00::1", "::ffff:192.168.0.7",
            "nas.local", "NAS.LOCAL.", "raspberrypi.local",
        ],
    )
    fun `direcciones y nombres de la red local`(host: String) {
        assertTrue(LocalNetworkHosts.isLocalHostName(host), host)
    }

    @ParameterizedTest
    @ValueSource(
        strings = [
            "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "190.102.110.8", "127.0.0.1", "::1",
            "100.64.0.1", "100.101.102.103", "2001:db8::1", "::ffff:8.8.8.8", "dev.example.com", "local",
            "mylocal", "", "999.1.1.1", "1.2.3",
        ],
    )
    fun `lo que no es red local`(host: String) {
        assertFalse(LocalNetworkHosts.isLocalHostName(host), host)
    }

    @Test
    fun `literal frente a nombre`() {
        assertTrue(LocalNetworkHosts.isIpLiteral("192.168.1.1"))
        assertTrue(LocalNetworkHosts.isIpLiteral("[2001:db8::1]"))
        assertFalse(LocalNetworkHosts.isIpLiteral("dev.example.com"))
    }

    @Test
    fun `la puerta solo bloquea si el permiso falta y el host es local`() {
        var granted = false
        val resolved = mutableListOf<String>()
        val gate = LocalNetworkGate({ true }, { granted }) { host ->
            resolved += host
            if (host == "nas.casa") listOf(byteArrayOf(192.toByte(), 168.toByte(), 1, 10)) else listOf(byteArrayOf(8, 8, 8, 8))
        }

        assertTrue(gate.blocks("192.168.1.5"))
        assertTrue(gate.blocks("nas.casa"))
        assertFalse(gate.blocks("dev.example.com"))
        assertFalse(gate.blocks("8.8.4.4"))
        // Los literales no pasan por el DNS.
        assertEquals(listOf("nas.casa", "dev.example.com"), resolved)

        granted = true
        assertFalse(gate.blocks("192.168.1.5"))
    }

    @Test
    fun `sin permiso que aplique nunca bloquea ni resuelve`() {
        val gate = LocalNetworkGate({ false }, { false }) { error("no debe resolver") }
        assertFalse(gate.blocks("192.168.1.5"))
        assertFalse(gate.isMissing)
        assertFalse(LocalNetworkGate.NotRequired.blocks("nas.local"))
    }

    @Test
    fun `un nombre que no resuelve no se toma por local`() {
        val gate = LocalNetworkGate({ true }, { false }) { throw UnknownHostException(it) }
        assertFalse(gate.blocks("no-existe.example"))
    }
}
