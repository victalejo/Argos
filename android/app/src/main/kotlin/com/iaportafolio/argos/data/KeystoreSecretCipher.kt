package com.iaportafolio.argos.data

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * [SecretCipher] con Android Keystore: una clave AES-256 por servidor, generada DENTRO del
 * Keystore (respaldada por TEE/StrongBox cuando existe) y no exportable. El IV lo elige el
 * Keystore en cada cifrado (aleatorio, 12 bytes) y se antepone al resultado.
 *
 * El `Cipher` se pide SIN proveedor explícito: con la selección diferida de JCA, al iniciarlo
 * con una clave del Keystore se elige el proveedor del Keystore aunque BouncyCastle esté
 * instalado en primera posición (lo necesitará sshj).
 */
class KeystoreSecretCipher : SecretCipher {

    private val keyStore: KeyStore by lazy { KeyStore.getInstance(KEYSTORE).apply { load(null) } }

    override fun encrypt(keyId: String, plaintext: ByteArray, aad: ByteArray): ByteArray = synchronized(this) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, keyFor(keyId, create = true))
        cipher.updateAAD(aad)
        val ciphertext = cipher.doFinal(plaintext)
        val iv = cipher.iv
        check(iv.size == IV_BYTES) { "IV inesperado del Keystore." }
        iv + ciphertext
    }

    override fun decrypt(keyId: String, blob: ByteArray, aad: ByteArray): ByteArray = synchronized(this) {
        if (blob.size <= IV_BYTES) throw GeneralSecurityException("Secreto cifrado truncado.")
        val key = keyFor(keyId, create = false)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES))
        cipher.updateAAD(aad)
        cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES)
    }

    override fun deleteKey(keyId: String) = synchronized(this) {
        val alias = alias(keyId)
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
    }

    private fun keyFor(keyId: String, create: Boolean): SecretKey {
        val alias = alias(keyId)
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) throw GeneralSecurityException("No hay clave en el Keystore para este servidor.")
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_BITS)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun alias(keyId: String) = "$ALIAS_PREFIX$keyId"

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val ALIAS_PREFIX = "argos.server.v1."
        const val KEY_BITS = 256
        const val TAG_BITS = 128
        const val IV_BYTES = 12
    }
}
