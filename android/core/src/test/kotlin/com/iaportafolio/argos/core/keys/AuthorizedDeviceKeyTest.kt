package com.iaportafolio.argos.core.keys

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Paridad con la suite «Dispositivos autorizados en authorized_keys» de `ServerTransferTests.swift`. */
class AuthorizedDeviceKeyTest {

    /** Generada con `ssh-keygen -t ed25519`; huella según `ssh-keygen -lf`. */
    private val line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXMXAfSBEWS5Z4ovI6/I3qqR6AVZEtQI4xfhTNLlQKA " +
        "argos-iphone-20261107-0f3c2a9e-1111-2222-3333-444455556666"
    private val fingerprint = "SHA256:MVvkj/8gGl39y3qOw1Iq48o1Z4T3FPJ7Vh2CO438AEA"

    @Test
    fun `lee comentario tipo huella igual que ssh-keygen y fecha`() {
        val key = assertNotNull(AuthorizedDeviceKey.parseLine(line))
        assertEquals("argos-iphone-20261107-0f3c2a9e-1111-2222-3333-444455556666", key.comment)
        assertEquals("ssh-ed25519", key.keyType)
        assertEquals(fingerprint, key.fingerprint)
        assertEquals("20261107", key.authorizedOn?.let(AuthorizedDeviceKey::dateStamp))
        assertEquals("0f3c2a9e", key.shortId)
    }

    @Test
    fun `ignora las claves que no son de Argos comentarios y lineas vacias`() {
        val text = """
            # mis claves
            ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXMXAfSBEWS5Z4ovI6/I3qqR6AVZEtQI4xfhTNLlQKA victor@mac

            ssh-rsa AAAAB3NzaC1yc2E= sin-comentario-argos
            $line
            ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXMXAfSBEWS5Z4ovI6/I3qqR6AVZEtQI4xfhTNLlQKA
        """.trimIndent()
        assertEquals(listOf("0f3c2a9e"), AuthorizedDeviceKey.parseAuthorizedKeys(text).map { it.shortId })
    }

    @Test
    fun `admite opciones delante del tipo de clave`() {
        val key = assertNotNull(AuthorizedDeviceKey.parseLine("no-agent-forwarding,no-pty $line"))
        assertEquals(fingerprint, key.fingerprint)
    }

    @Test
    fun `formato antiguo sin fecha fecha desconocida`() {
        val legacy = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKXMXAfSBEWS5Z4ovI6/I3qqR6AVZEtQI4xfhTNLlQKA " +
            "argos-iphone-0f3c2a9e-1111-2222-3333-444455556666"
        val key = assertNotNull(AuthorizedDeviceKey.parseLine(legacy))
        assertNull(key.authorizedOn)
        assertEquals("0f3c2a9e", key.shortId)
    }

    @ParameterizedTest
    @ValueSource(strings = ["20261340", "2026110", "2026a107", "", "20260230", "２０２６１１０７"])
    fun `rechaza fechas imposibles o mal formadas`(stamp: String) {
        assertNull(AuthorizedDeviceKey.dateFromStamp(stamp))
    }

    @Test
    fun `blob base64 sin relleno se rechaza como en Swift`() {
        val unpadded = "ssh-rsa AAAAB3NzaC1yc2E argos-iphone-x"
        assertNull(AuthorizedDeviceKey.parseLine(unpadded))
    }

    @Test
    fun `la huella de una clave generada por Argos coincide con su blob`() {
        val key = Ed25519Key.generate()
        val generated = OpenSSHKeyWriter.authorizedKeyLine(key.publicKey, ServerTransfer.makeKeyComment())
        val parsed = assertNotNull(AuthorizedDeviceKey.parseLine(generated))
        assertEquals(AuthorizedDeviceKey.fingerprintOfBlob(OpenSSHKeyWriter.publicKeyBlob(key.publicKey)), parsed.fingerprint)
        assertNotNull(parsed.authorizedOn)
    }

    @Test
    fun `la linea del Mac produce la huella esperada`() {
        val parsed = assertNotNull(AuthorizedDeviceKey.parseLine(SwiftVectors.AUTHORIZED_LINE))
        assertEquals(
            AuthorizedDeviceKey.fingerprintOfBlob(OpenSSHKeyWriter.publicKeyBlob(SwiftVectors.key.publicKey)),
            parsed.fingerprint,
        )
    }
}
