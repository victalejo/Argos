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
    fun `un archivo inválido se trata como vacío`() {
        file.writeText("[1,2")
        assertNull(FileHostKeyTrustStore(file).trustedFingerprint("a:22"))
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
