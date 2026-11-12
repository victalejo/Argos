package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.keys.Ed25519Key
import com.iaportafolio.argos.core.keys.OpenSSHKeyWriter
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.readText
import kotlin.io.path.writeText
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Huella, almacén TOFU en JSON y rutas de subida (sin red). */
class HostKeyStoreAndPathsTest {

    @TempDir
    lateinit var dir: Path

    // MARK: Huella

    @Test
    fun `la huella del blob coincide con ssh-keygen -l`() {
        val publicKey = Ed25519Key.generate().publicKey
        val pub = dir.resolve("k.pub").apply { writeText(OpenSSHKeyWriter.authorizedKeyLine(publicKey, "c") + "\n") }
        assertEquals(sshKeygenFingerprint(pub), HostKeyFingerprint.ofBlob(OpenSSHKeyWriter.publicKeyBlob(publicKey)))
    }

    @Test
    fun `la huella no lleva relleno y tiene el prefijo de OpenSSH`() {
        val fingerprint = HostKeyFingerprint.ofBlob(byteArrayOf(1, 2, 3))
        assertTrue(fingerprint.startsWith("SHA256:"))
        assertFalse(fingerprint.contains('='))
        assertEquals(7 + 43, fingerprint.length)
    }

    // MARK: JsonHostKeyTrustStore

    @Test
    fun `sin archivo no hay huellas y trust crea el JSON`() {
        val file = dir.resolve("sub/known_hosts.json")
        val store = JsonHostKeyTrustStore(file)
        assertNull(store.trustedFingerprint("h:22"))
        store.trust("h:22", "SHA256:abc/def+g")
        assertEquals("""{"h:22":"SHA256:abc/def+g"}""", file.readText())
        assertEquals("SHA256:abc/def+g", JsonHostKeyTrustStore(file).trustedFingerprint("h:22"))
    }

    @Test
    fun `lee el known_hosts json de Apple con barras escapadas`() {
        val file = dir.resolve("known_hosts.json").apply { writeText("""{"dev:22":"SHA256:a\/b","x:2222":"SHA256:c"}""") }
        val store = JsonHostKeyTrustStore(file)
        assertEquals(mapOf("dev:22" to "SHA256:a/b", "x:2222" to "SHA256:c"), store.allTrusted())
    }

    @Test
    fun `forget elimina solo ese endpoint`() {
        val store = JsonHostKeyTrustStore(dir.resolve("k.json"))
        store.trust("a:22", "SHA256:a")
        store.trust("b:22", "SHA256:b")
        store.forget("a:22")
        store.forget("nada:22")
        assertEquals(mapOf("b:22" to "SHA256:b"), store.allTrusted())
    }

    @Test
    fun `trustIfUnknown nunca sustituye una huella distinta`() {
        val store = JsonHostKeyTrustStore(dir.resolve("k.json"))
        assertTrue(store.trustIfUnknown("a:22", "SHA256:qr"))
        assertTrue(store.trustIfUnknown("a:22", "SHA256:qr"))
        assertFalse(store.trustIfUnknown("a:22", "SHA256:otra"))
        assertEquals("SHA256:qr", store.trustedFingerprint("a:22"))
    }

    @Test
    fun `un archivo corrupto cuenta como vacío y se notifica`() {
        val file = dir.resolve("k.json").apply { writeText("no es json") }
        val reported = mutableListOf<Path>()
        val store = JsonHostKeyTrustStore(file) { path, _ -> reported.add(path) }
        assertNull(store.trustedFingerprint("a:22"))
        assertEquals(listOf(file), reported)
    }

    @Test
    fun `escrituras concurrentes no pierden huellas ni dejan temporales`() {
        val file = dir.resolve("k.json")
        val pool = Executors.newFixedThreadPool(8)
        repeat(64) { index -> pool.execute { JsonHostKeyTrustStore(file).trust("h$index:22", "SHA256:$index") } }
        pool.shutdown()
        assertTrue(pool.awaitTermination(30, TimeUnit.SECONDS))
        assertEquals(64, JsonHostKeyTrustStore(file).allTrusted().size)
        assertEquals(listOf(file), dir.listDirectoryEntries())
    }

    @Test
    fun `el verificador TOFU confía la primera vez y rechaza después una huella distinta`() {
        val store = JsonHostKeyTrustStore(dir.resolve("k.json"))
        val key = java.security.KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair().public
        val other = java.security.KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair().public

        assertTrue(TofuHostKeyVerifier("h:22", store).verify("h", 22, key))
        assertTrue(TofuHostKeyVerifier("h:22", store).verify("h", 22, key))
        val verifier = TofuHostKeyVerifier("h:22", store)
        assertFalse(verifier.verify("h", 22, other))
        assertEquals(HostKeyFingerprint.of(key), verifier.mismatch?.storedFingerprint)
        assertEquals(HostKeyFingerprint.of(other), verifier.mismatch?.presentedFingerprint)
        assertTrue(Files.exists(dir.resolve("k.json")))
    }

    @Test
    fun `con el registro dañado el verificador aborta en vez de volver a confiar`() {
        val unreadable = object : com.iaportafolio.argos.core.HostKeyTrustStore {
            var trusted = 0
            override fun trustedFingerprint(endpoint: String): String? = null
            override fun trust(endpoint: String, fingerprint: String) { trusted++ }
            override fun forget(endpoint: String) = Unit
            override fun isReadable(): Boolean = false
        }
        val key = java.security.KeyPairGenerator.getInstance("EC").apply { initialize(256) }.generateKeyPair().public
        val verifier = TofuHostKeyVerifier("h:22", unreadable)

        assertFalse(verifier.verify("h", 22, key))
        assertTrue(verifier.rejection is com.iaportafolio.argos.core.HostKeyStoreUnreadableException)
        assertEquals(0, unreadable.trusted)
    }

    // MARK: Rutas de subida

    @Test
    fun `sanea nombres como Apple`() {
        assertEquals("foto.png", UploadPaths.sanitize("foto.png"))
        assertEquals("mi_foto_.txt", UploadPaths.sanitize("/Users/x/mi foto!.txt"))
        assertEquals("a_o.txt", UploadPaths.sanitize("año.txt"))
        assertEquals("__.txt", UploadPaths.sanitize("😀́.txt"))
        assertEquals("dir", UploadPaths.sanitize("a/dir/"))
        assertEquals("_", UploadPaths.sanitize("///"))
        assertEquals("archivo", UploadPaths.sanitize(""))
    }

    @Test
    fun `rutas remotas de subida en tmp`() {
        assertEquals("/tmp/argos-pasted-42.png", UploadPaths.pasted("png", 42))
        assertEquals("/tmp/argos-42-a_b.txt", UploadPaths.dropped("a b.txt", 42))
    }

    @Test
    fun `vaciar las conexiones dedicadas no falla si otra corrutina las retira a la vez`() {
        val set: MutableSet<Int> = java.util.concurrent.ConcurrentHashMap.newKeySet()
        val stop = java.util.concurrent.atomic.AtomicBoolean(false)
        val churn = kotlin.concurrent.thread {
            while (!stop.get()) {
                set += 1
                set -= 1
            }
        }
        try {
            repeat(2_000_000) { set.drainConcurrently() }
        } finally {
            stop.set(true)
            churn.join()
        }
    }
}
