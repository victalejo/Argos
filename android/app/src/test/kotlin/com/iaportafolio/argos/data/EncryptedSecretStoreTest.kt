package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.keys.ImportedKeyValidation
import com.iaportafolio.argos.testing.SoftwareCipher
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EncryptedSecretStoreTest {

    @TempDir
    lateinit var dir: File

    private val cipher = SoftwareCipher()
    private val store by lazy { EncryptedSecretStore(dir, cipher) }

    private val key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"

    @Test
    fun `guarda y lee cada tipo por servidor`() {
        store.write("A", SecretKind.PASSWORD, "pw-a")
        store.write("A", SecretKind.PASSPHRASE, "frase")
        store.write("B", SecretKind.PASSWORD, "pw-b")

        assertEquals("pw-a", store.read("A", SecretKind.PASSWORD))
        assertEquals("frase", store.read("A", SecretKind.PASSPHRASE))
        assertEquals("pw-b", store.read("B", SecretKind.PASSWORD))
        assertNull(store.read("A", SecretKind.PRIVATE_KEY))
        assertTrue(store.contains("A", SecretKind.PASSWORD))
        assertFalse(store.contains("B", SecretKind.PASSPHRASE))
    }

    @Test
    fun `nunca escribe el secreto en claro ni el id en el nombre`() {
        store.write("SERVIDOR-1", SecretKind.PASSWORD, "contraseña-super-secreta")
        val files = dir.listFiles().orEmpty()
        assertEquals(1, files.size)
        assertFalse("SERVIDOR-1" in files[0].name)
        val bytes = files[0].readBytes()
        assertFalse("contraseña-super-secreta".encodeToByteArray().toList().windowed(8).any { window ->
            bytes.toList().windowed(8).contains(window)
        })
    }

    @Test
    fun `un blob copiado a otro servidor o tipo no se descifra`() {
        store.write("A", SecretKind.PASSWORD, "pw-a")
        store.write("B", SecretKind.PASSWORD, "pw-b")
        val fileA = File(dir, "${EncryptedSecretStore.token("A")}.password.bin")
        val fileB = File(dir, "${EncryptedSecretStore.token("B")}.password.bin")
        fileA.copyTo(fileB, overwrite = true)

        assertFailsWith<SecretUnavailableException> { store.read("B", SecretKind.PASSWORD) }

        val passphraseA = File(dir, "${EncryptedSecretStore.token("A")}.passphrase.bin")
        fileA.copyTo(passphraseA)
        assertFailsWith<SecretUnavailableException> { store.read("A", SecretKind.PASSPHRASE) }
    }

    @Test
    fun `un blob alterado o sin clave lanza SecretUnavailable con mensaje accionable`() {
        store.write("A", SecretKind.PASSWORD, "pw")
        val file = File(dir, "${EncryptedSecretStore.token("A")}.password.bin")
        val bytes = file.readBytes()
        bytes[bytes.size - 1] = (bytes.last() + 1).toByte()
        file.writeBytes(bytes)

        val error = assertFailsWith<SecretUnavailableException> { store.read("A", SecretKind.PASSWORD) }
        assertTrue(error.message.orEmpty().contains("Edita el servidor"))
    }

    @Test
    fun `delete y deleteAll borran archivos y destruyen la clave`() {
        store.write("A", SecretKind.PASSWORD, "pw")
        store.write("A", SecretKind.PRIVATE_KEY, key)
        store.write("B", SecretKind.PASSWORD, "otro")

        store.delete("A", SecretKind.PASSWORD)
        assertNull(store.read("A", SecretKind.PASSWORD))
        assertEquals(key, store.read("A", SecretKind.PRIVATE_KEY))

        store.deleteAll("A")
        assertNull(store.read("A", SecretKind.PRIVATE_KEY))
        assertEquals(listOf(EncryptedSecretStore.token("A")), cipher.deletedKeys)
        assertEquals("otro", store.read("B", SecretKind.PASSWORD))
    }

    @Test
    fun `importPrivateKey valida y normaliza`() {
        store.importPrivateKey("A", "  $key  ".encodeToByteArray())
        assertEquals("$key\n", store.read("A", SecretKind.PRIVATE_KEY))
    }

    @Test
    fun `importPrivateKey rechaza lo que no es una clave OpenSSH sin guardar nada`() {
        val error = assertFailsWith<ImportedKeyValidation.ImportException> {
            store.importPrivateKey("A", "ssh-ed25519 AAAA pública".encodeToByteArray())
        }
        assertEquals(ImportedKeyValidation.Reason.NOT_OPENSSH_KEY, error.reason)
        assertFalse(store.contains("A", SecretKind.PRIVATE_KEY))

        assertFailsWith<ImportedKeyValidation.ImportException> {
            store.importPrivateKey("A", ByteArray(ImportedKeyValidation.MAX_BYTES + 1))
        }
    }

    @Test
    fun `el token es estable, hexadecimal y no escapa del directorio`() {
        val token = EncryptedSecretStore.token("../../etc/passwd")
        assertEquals(token, EncryptedSecretStore.token("../../etc/passwd"))
        assertTrue(token.matches(Regex("[0-9a-f]{32}")))
        store.write("../../etc/passwd", SecretKind.PASSWORD, "x")
        assertContentEquals(arrayOf("$token.password.bin"), dir.list())
    }
}
