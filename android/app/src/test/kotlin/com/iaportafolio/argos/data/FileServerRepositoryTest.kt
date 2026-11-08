package com.iaportafolio.argos.data

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.testing.server
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FileServerRepositoryTest {

    @TempDir
    lateinit var dir: File

    private val file get() = File(dir, "servers.json")

    private fun repository(scheduler: kotlinx.coroutines.test.TestCoroutineScheduler) =
        FileServerRepository(file, StandardTestDispatcher(scheduler), clock = { 42L })

    @Test
    fun `sin archivo empieza vacío`() = runTest {
        assertEquals(emptyList(), repository(testScheduler).servers.value)
    }

    @Test
    fun `upsert persiste y otra instancia lo relee`() = runTest {
        val repo = repository(testScheduler)
        repo.upsert(server(id = "A"))
        repo.upsert(server(id = "B", name = "prod"))

        assertEquals(listOf("A", "B"), repo.servers.value.map { it.id })
        assertEquals(repo.servers.value, repository(testScheduler).servers.value)
    }

    @Test
    fun `upsert de un id existente reemplaza en su sitio`() = runTest {
        val repo = repository(testScheduler)
        repo.upsert(server(id = "A"))
        repo.upsert(server(id = "B"))
        repo.upsert(server(id = "A", name = "renombrado"))

        assertEquals(listOf("A", "B"), repo.servers.value.map { it.id })
        assertEquals("renombrado", repo.server("A")?.name)
    }

    @Test
    fun `delete borra y persiste`() = runTest {
        val repo = repository(testScheduler)
        repo.upsert(server(id = "A"))
        repo.delete("A")
        repo.delete("no-existe")

        assertNull(repo.server("A"))
        assertEquals(emptyList(), repository(testScheduler).servers.value)
    }

    @Test
    fun `escritura atómica no deja temporales`() = runTest {
        val repo = repository(testScheduler)
        repeat(3) { repo.upsert(server(id = "S$it")) }
        assertEquals(listOf("servers.json"), dir.list()?.toList())
    }

    @Test
    fun `lee el servers json de Apple con claves extra y valores por defecto`() = runTest {
        file.writeText(
            """
            [{"id":"0F1E2D3C-AAAA-BBBB-CCCC-123456789ABC","name":"mac","host":"10.0.0.2","port":2222,
              "username":"vic","privateKeyBookmark":"AAAA"},
             {"id":"X","name":"pw","host":"h","port":22,"username":"u","authMethod":"password",
              "privateKeyPath":"","requiresPassphrase":false}]
            """.trimIndent(),
        )
        val servers = repository(testScheduler).servers.value
        assertEquals(2, servers.size)
        assertEquals(AuthMethod.KEY, servers[0].authMethod)
        assertEquals(2222, servers[0].port)
        assertEquals(AuthMethod.PASSWORD, servers[1].authMethod)
    }

    @Test
    fun `escribe un array JSON con todas las claves (compatible con Apple)`() = runTest {
        repository(testScheduler).upsert(server(id = "A"))
        val text = file.readText()
        assertTrue(text.startsWith("["))
        listOf("\"authMethod\":\"password\"", "\"privateKeyPath\":\"\"", "\"requiresPassphrase\":false", "\"port\":22")
            .forEach { assertTrue(it in text, "falta $it en $text") }
    }

    @Test
    fun `un archivo corrupto se aparta en vez de sobrescribirse`() = runTest {
        file.writeText("{esto no es json")
        val repo = repository(testScheduler)

        assertEquals(emptyList(), repo.servers.value)
        assertFalse(file.exists())
        assertEquals("{esto no es json", File(dir, "servers.json.corrupt-42").readText())

        repo.upsert(server(id = "A"))
        assertEquals(listOf("A"), repository(testScheduler).servers.value.map { it.id })
    }
}
