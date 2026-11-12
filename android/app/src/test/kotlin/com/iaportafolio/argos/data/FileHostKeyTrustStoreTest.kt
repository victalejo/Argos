package com.iaportafolio.argos.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FileHostKeyTrustStoreTest {

    @TempDir
    lateinit var dir: File

    private val file get() = File(dir, "known_hosts.json")

    @Test
    fun `confía, persiste con el formato de Apple y olvida`() {
        val store = FileHostKeyTrustStore(file)
        assertNull(store.trustedFingerprint("h:22"))

        store.trust("h:22", "SHA256:abc")
        assertEquals("SHA256:abc", store.trustedFingerprint("h:22"))
        val json = Json.parseToJsonElement(file.readText()).jsonObject
        assertEquals("SHA256:abc", json.getValue("h:22").jsonPrimitive.content)

        assertEquals("SHA256:abc", FileHostKeyTrustStore(file).trustedFingerprint("h:22"))

        store.forget("h:22")
        assertNull(store.trustedFingerprint("h:22"))
        assertNull(FileHostKeyTrustStore(file).trustedFingerprint("h:22"))
    }

    @Test
    fun `olvidar un endpoint desconocido no crea el archivo`() {
        FileHostKeyTrustStore(file).forget("nada:22")
        assertTrue(!file.exists())
    }

    @Test
    fun `lee un known_hosts json existente de Apple`() {
        file.writeText("""{"a:22":"SHA256:x","b:2222":"SHA256:y"}""")
        val store = FileHostKeyTrustStore(file)
        assertEquals("SHA256:y", store.trustedFingerprint("b:2222"))
    }

    @Test
    fun `un archivo inválido no se lee como vacío ni admite cambios`() {
        file.writeText("[1,2")
        val store = FileHostKeyTrustStore(file)
        assertTrue(!store.isReadable())
        assertNull(store.trustedFingerprint("a:22"))

        // Ni confiar ni una limpieza automática lo reinician.
        store.trust("a:22", "SHA256:x")
        store.forget("a:22")
        assertEquals("[1,2", file.readText())
        assertTrue(!FileHostKeyTrustStore(file).isReadable())
    }

    @Test
    fun `olvidar host key a mano aparta el archivo dañado y empieza uno nuevo`() {
        file.writeText("[1,2")
        val store = FileHostKeyTrustStore(file)

        store.forgetExplicitly("a:22")

        assertTrue(store.isReadable())
        assertTrue(!file.exists())
        assertEquals(1, dir.listFiles { f -> f.name.startsWith("known_hosts.json.corrupt-") }!!.size)
        store.trust("a:22", "SHA256:x")
        assertEquals("SHA256:x", FileHostKeyTrustStore(file).trustedFingerprint("a:22"))
    }

    @Test
    fun `con el archivo sano, olvidar a mano solo quita ese servidor`() {
        val store = FileHostKeyTrustStore(file)
        store.trust("a:22", "SHA256:a")
        store.trust("b:22", "SHA256:b")
        store.forgetExplicitly("a:22")
        assertNull(store.trustedFingerprint("a:22"))
        assertEquals("SHA256:b", store.trustedFingerprint("b:22"))
    }

    @Test
    fun `escrituras concurrentes no pierden entradas`() {
        val store = FileHostKeyTrustStore(file)
        val pool = Executors.newFixedThreadPool(8)
        val count = 64
        val done = CountDownLatch(count)
        repeat(count) { i ->
            pool.execute {
                store.trust("h$i:22", "SHA256:$i")
                done.countDown()
            }
        }
        assertTrue(done.await(10, TimeUnit.SECONDS))
        pool.shutdown()

        val reloaded = FileHostKeyTrustStore(file)
        repeat(count) { i -> assertEquals("SHA256:$i", reloaded.trustedFingerprint("h$i:22")) }
    }
}
