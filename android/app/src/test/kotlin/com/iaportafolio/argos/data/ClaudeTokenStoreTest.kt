package com.iaportafolio.argos.data

import com.iaportafolio.argos.testing.SoftwareCipher
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ClaudeTokenStoreTest {

    @TempDir
    lateinit var dir: File

    private val cipher = SoftwareCipher()
    private val secrets by lazy { EncryptedSecretStore(dir, cipher) }
    private val tokens by lazy { SecretStoreClaudeTokens(secrets) }

    @Test
    fun `guarda, lee y borra el token`() {
        assertFalse(tokens.hasToken())
        assertNull(tokens.read())

        tokens.save("sk-ant-oat01-abc")
        assertTrue(tokens.hasToken())
        assertEquals("sk-ant-oat01-abc", tokens.read())

        tokens.delete()
        assertFalse(tokens.hasToken())
        assertNull(tokens.read())
    }

    @Test
    fun `nunca queda en claro en disco`() {
        tokens.save("sk-ant-oat01-abc")
        val files = dir.listFiles().orEmpty()
        assertTrue(files.isNotEmpty())
        files.forEach { assertFalse("sk-ant" in it.readBytes().decodeToString(), it.name) }
    }

    @Test
    fun `es global, borrar un servidor no lo toca`() {
        tokens.save("sk-ant-oat01-abc")
        secrets.write("servidor", SecretKind.PASSWORD, "clave")
        secrets.deleteAll("servidor")
        assertEquals("sk-ant-oat01-abc", tokens.read())
    }

    @Test
    fun `un blob ilegible da un error propio sin el secreto`() {
        tokens.save("sk-ant-oat01-abc")
        cipher.keys.clear()
        val error = assertFailsWith<ClaudeTokenUnavailableException> { tokens.read() }
        assertFalse("sk-ant" in error.message.orEmpty())
    }

    @Test
    fun `el token pegado se limpia y debe ser una sola palabra`() {
        assertEquals("abc", ClaudeTokenValidation.normalize("  abc\n"))
        assertNull(ClaudeTokenValidation.normalize("   "))
        assertNull(ClaudeTokenValidation.normalize("abc def"))
        // Viaja como una línea por stdin: un salto interior separaría el token del script.
        assertNull(ClaudeTokenValidation.normalize("abc\ndef"))
        assertNull(ClaudeTokenValidation.normalize("abc\u0007"))
        assertNull(ClaudeTokenValidation.normalize("x".repeat(5_000)))
    }
}
