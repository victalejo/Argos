package com.iaportafolio.argos.ssh

import net.schmizz.sshj.common.Buffer
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64

/**
 * Huella de host key con el formato de OpenSSH (`ssh-keygen -l`): `SHA256:` + base64 del
 * SHA-256 del blob SSH de la clave pública, sin el relleno `=`.
 *
 * Idéntica a `TOFUHostKeyValidator.fingerprint(of:)` de Apple, que hashea lo que escribe
 * `NIOSSHPublicKey.write(to:)`: el mismo blob (`string tipo` + datos de la clave) que
 * serializa sshj con `putPublicKey`. Así las huellas del Mac (QR) y de Android son comparables.
 */
object HostKeyFingerprint {
    private const val PREFIX = "SHA256:"

    /** Huella del blob SSH ya serializado. */
    fun ofBlob(blob: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(blob)
        return PREFIX + Base64.getEncoder().withoutPadding().encodeToString(digest)
    }

    /** Huella de una clave pública tal como la entrega sshj al verificar el host. */
    fun of(key: PublicKey): String = ofBlob(Buffer.PlainBuffer().putPublicKey(key).compactData)
}
