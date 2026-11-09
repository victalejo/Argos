package com.iaportafolio.argos.core.keys

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class PastedKeyValidationTest {

    private val pem = OpenSSHKeyWriter.privateKeyPem(Ed25519Key.generate(), "prueba")

    private fun reason(text: String) =
        assertFailsWith<ImportedKeyValidation.ImportException> { ImportedKeyValidation.validatePasted(text) }.reason

    @Test
    fun `una clave pegada tal cual se conserva`() {
        assertEquals(pem, ImportedKeyValidation.validatePasted(pem))
    }

    @Test
    fun `se reconstruyen los saltos de línea que pierden las apps de mensajería`() {
        val body = pem.removePrefix(ImportedKeyValidation.HEADER).trim().removeSuffix(OpenSSHKeyWriter.PEM_FOOTER).trim()
        val flattened = "${ImportedKeyValidation.HEADER} ${body.replace("\n", " ")} ${OpenSSHKeyWriter.PEM_FOOTER}"
        assertEquals(pem, ImportedKeyValidation.validatePasted(flattened))

        val crlf = "  \r\n" + pem.replace("\n", "\r\n") + "\r\n\r\n"
        assertEquals(pem, ImportedKeyValidation.validatePasted(crlf))
    }

    @Test
    fun `se ignora el texto alrededor de la clave`() {
        assertEquals(pem, ImportedKeyValidation.validatePasted("Aquí va mi clave:\n$pem\nGracias"))
    }

    @Test
    fun `se rechaza lo que no es una clave privada OpenSSH`() {
        assertEquals(ImportedKeyValidation.Reason.PASTED_NOT_OPENSSH_KEY, reason(""))
        assertEquals(ImportedKeyValidation.Reason.PASTED_NOT_OPENSSH_KEY, reason("ssh-ed25519 AAAA usuario@mac"))
        assertEquals(ImportedKeyValidation.Reason.PASTED_NOT_OPENSSH_KEY, reason("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----"))
    }

    @Test
    fun `se rechaza una clave cortada o con caracteres extraños`() {
        assertEquals(ImportedKeyValidation.Reason.PASTED_INCOMPLETE, reason(pem.substringBefore(OpenSSHKeyWriter.PEM_FOOTER)))
        assertEquals(
            ImportedKeyValidation.Reason.PASTED_INCOMPLETE,
            reason("${ImportedKeyValidation.HEADER}\n${OpenSSHKeyWriter.PEM_FOOTER}"),
        )
        assertEquals(
            ImportedKeyValidation.Reason.PASTED_INCOMPLETE,
            reason("${ImportedKeyValidation.HEADER}\nAAAA…ñ\n${OpenSSHKeyWriter.PEM_FOOTER}"),
        )
    }

    @Test
    fun `se rechaza un texto demasiado largo`() {
        assertEquals(ImportedKeyValidation.Reason.TOO_LARGE, reason("A".repeat(ImportedKeyValidation.MAX_BYTES + 1)))
    }
}
