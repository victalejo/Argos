package com.iaportafolio.argos.core.keys

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Validación de claves importadas (paridad con lo puro de `ArgosTests/ImportedKeyStoreTests.swift`)
 * y comandos de ficheros privados en el `$HOME` remoto (`RemotePrivateFile.swift`).
 */
class RemoteKeyFilesTest {

    private val sampleKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        -----END OPENSSH PRIVATE KEY-----
    """.trimIndent()

    private fun reason(data: ByteArray) =
        assertFailsWith<ImportedKeyValidation.ImportException> { ImportedKeyValidation.validate(data) }.reason

    @Test
    fun `acepta clave OpenSSH y normaliza el final`() {
        val text = ImportedKeyValidation.validate("\n  $sampleKey\n\n".toByteArray())
        assertTrue(text.startsWith(ImportedKeyValidation.HEADER))
        assertTrue(text.endsWith("-----END OPENSSH PRIVATE KEY-----\n"))
    }

    @Test
    fun `rechaza archivos que no son clave`() {
        assertEquals(ImportedKeyValidation.Reason.NOT_OPENSSH_KEY, reason("ssh-ed25519 AAAA… usuario@mac".toByteArray()))
        assertEquals(ImportedKeyValidation.Reason.NOT_OPENSSH_KEY, reason("-----BEGIN RSA PRIVATE KEY-----\nabc".toByteArray()))
    }

    @Test
    fun `rechaza archivos enormes y binarios`() {
        assertEquals(ImportedKeyValidation.Reason.TOO_LARGE, reason(ByteArray(ImportedKeyValidation.MAX_BYTES + 1) { 65 }))
        assertEquals(ImportedKeyValidation.Reason.UNREADABLE, reason(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0xFD.toByte())))
    }

    @Test
    fun `leer un fichero del home silencia el error si no existe`() {
        assertEquals(
            "cat \"\$HOME/.claude/settings.json\" 2>/dev/null",
            RemoteHomeFileCommands.read(".claude/settings.json"),
        )
    }

    @Test
    fun `preparar la escritura crea la carpeta y el temporal bajo umask 077`() {
        assertEquals(
            "umask 077 && mkdir -p \"\$HOME/.config/argos\" && : > \"\$HOME/.config/argos/projects.json.argos-tmp\" " +
                "&& printf '%s' \"\$HOME\"",
            RemoteHomeFileCommands.prepareWrite(".config/argos/projects.json"),
        )
    }

    @Test
    fun `con copia de seguridad se copia antes el fichero existente`() {
        val command = RemoteHomeFileCommands.prepareWrite(".claude/settings.json", backup = true)
        assertTrue(
            command.contains(
                " && { [ ! -f \"\$HOME/.claude/settings.json\" ] || " +
                    "cp \"\$HOME/.claude/settings.json\" \"\$HOME/.claude/settings.json.argos-backup\"; } && ",
            ),
        )
        assertTrue(command.startsWith("umask 077 && mkdir -p \"\$HOME/.claude\" && {"))
    }

    @Test
    fun `ruta SFTP del temporal solo con un home absoluto`() {
        assertEquals("/home/v/.claude/settings.json.argos-tmp", RemoteHomeFileCommands.tempUploadPath("/home/v\n", ".claude/settings.json"))
        assertNull(RemoteHomeFileCommands.tempUploadPath("", ".claude/settings.json"))
        assertNull(RemoteHomeFileCommands.tempUploadPath("~", ".claude/settings.json"))
    }

    @Test
    fun `el reemplazo final es atomico con mv`() {
        assertEquals(
            "mv \"\$HOME/.claude/settings.json.argos-tmp\" \"\$HOME/.claude/settings.json\"",
            RemoteHomeFileCommands.commitWrite(".claude/settings.json"),
        )
    }
}
