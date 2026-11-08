package com.iaportafolio.argos.data

/**
 * Cifrado autenticado de secretos con una clave por servidor ([keyId] = id del servidor).
 *
 * En producción es [KeystoreSecretCipher] (Android Keystore, AES-GCM, clave no exportable);
 * en los tests JVM, una implementación AES-GCM con claves en memoria. Así toda la lógica de
 * [EncryptedSecretStore] se prueba sin Android.
 */
interface SecretCipher {
    /** Devuelve `iv || ciphertext+tag`. [aad] se autentica pero no se cifra. */
    fun encrypt(keyId: String, plaintext: ByteArray, aad: ByteArray): ByteArray

    /** Lanza [java.security.GeneralSecurityException] si la clave no existe o el blob se alteró. */
    fun decrypt(keyId: String, blob: ByteArray, aad: ByteArray): ByteArray

    /** Destruye la clave: lo cifrado con ella queda irrecuperable («crypto-shredding»). */
    fun deleteKey(keyId: String)
}
