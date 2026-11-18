package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.keys.RemoteHomeFileCommands
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Path
import java.time.Instant
import kotlin.io.path.createDirectories
import kotlin.io.path.exists
import kotlin.io.path.readText
import kotlin.io.path.writeText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Reglas de `projects.json` compartido: nada se pierde al reescribir y nunca se pisa a otro. */
class ProjectsDocumentTest {

    private fun project(n: Int, name: String = "p$n") = Project(
        id = "6F1C2A3B-0000-4000-8000-00000000000$n",
        name = name,
        path = "/srv/$name",
        createdAt = Instant.ofEpochSecond(1_762_509_600),
    )

    private fun fileWith(vararg projects: String, extra: String = "") =
        """{"version":1$extra,"projects":[${projects.joinToString(",")}]}"""

    private fun json(project: Project, extra: String = ""): String =
        """{"id":"${project.id}","name":"${project.name}","path":"${project.path}",""" +
            """"createdAt":"2025-11-07T10:00:00Z"$extra}"""

    @Test
    fun `sin nada desconocido escribe los mismos bytes que ProjectsFile`() {
        val projects = listOf(project(1), project(2))
        val expected = ProjectsFile(projects = projects).encodedText()
        val document = ProjectsDocument.decode(expected)
        assertEquals(expected, document.encodedText())
        assertEquals(ProjectsFile.EMPTY.encodedText(), ProjectsDocument.EMPTY.encodedText())
        assertEquals(expected, ProjectsDocument.EMPTY.applying(emptyList(), projects).encodedText())
    }

    @Test
    fun `conserva las claves desconocidas del archivo y de cada proyecto`() {
        val text = fileWith(json(project(1), extra = ""","color":"rojo","tags":[1,2]"""), extra = ""","futuro":{"a":true}""")
        val document = ProjectsDocument.decode(text)
        val renamed = document.projects.map { it.copy(name = "nuevo") }
        val written = ProjectsDocument.decode(document.applying(document.projects, renamed).encodedText())

        assertEquals(JsonPrimitive(true), written.extras["futuro"]?.jsonObject?.get("a"))
        val entry = assertIs<ProjectRecord.Readable>(written.entries.single())
        assertEquals("nuevo", entry.project.name)
        assertEquals(JsonPrimitive("rojo"), entry.extras["color"])
        assertTrue("tags" in entry.extras)
    }

    @Test
    fun `una version mas nueva se lee pero se niega a escribir`() {
        val document = ProjectsDocument.decode("""{"version":2,"projects":[${json(project(1))}]}""")
        assertEquals(listOf("p1"), document.projects.map { it.name })
        val error = assertFailsWith<ProjectError.UnsupportedVersion> { document.requireWritable() }
        assertEquals(2, error.version)
        assertTrue(error.message.orEmpty().contains("Actualiza Argos en este dispositivo"))
        ProjectsDocument.decode(fileWith()).requireWritable()
    }

    @Test
    fun `un proyecto invalido no invalida el resto y se conserva en su sitio`() {
        val broken = """{"id":"no-es-uuid","name":"roto"}"""
        val document = ProjectsDocument.decode(fileWith(json(project(1)), broken, "42", json(project(2))))
        assertEquals(listOf("p1", "p2"), document.projects.map { it.name })

        val withoutFirst = document.applying(document.projects, listOf(project(2), project(3)))
        val rewritten = ProjectsDocument.decode(withoutFirst.encodedText())
        assertEquals(listOf("p2", "p3"), rewritten.projects.map { it.name })
        val raw = rewritten.entries.filterIsInstance<ProjectRecord.Unreadable>().map { it.raw.toString() }
        assertEquals(listOf(broken, "42"), raw)
        assertIs<ProjectRecord.Unreadable>(rewritten.entries[1])
    }

    @Test
    fun `archivo que no es un objeto con version y lista sigue siendo invalido`() {
        for (text in listOf("{ roto", "[]", """{"projects":[]}""", """{"version":"1","projects":[]}""", """{"version":1,"projects":{}}""")) {
            assertEquals(ProjectError.InvalidFile, assertFailsWith<ProjectError> { ProjectsDocument.decode(text) }, text)
        }
        assertEquals(ProjectsDocument.EMPTY, ProjectsDocument.decode(" \n"))
    }

    @Test
    fun `reaplicar el cambio respeta lo que otro dispositivo hizo entretanto`() {
        val base = listOf(project(1), project(2), project(3))
        // La app renombra p1, borra p3 y añade p5.
        val updated = listOf(project(1, "uno"), project(2), project(5))
        // Mientras tanto, otro dispositivo editó p2, borró nada y añadió p4.
        val current = ProjectsDocument.decode(
            fileWith(json(project(1)), json(project(2, "dos-remoto")), json(project(3)), json(project(4))),
        )
        val merged = current.applying(base, updated)
        assertEquals(listOf("uno", "dos-remoto", "p5", "p4"), merged.projects.map { it.name })
    }

    @Test
    fun `un proyecto sin tocar que otro borro sigue borrado`() {
        val base = listOf(project(1), project(2))
        val current = ProjectsDocument.decode(fileWith(json(project(1))))
        val merged = current.applying(base, listOf(project(1), project(2), project(3)))
        assertEquals(listOf("p1", "p3"), merged.projects.map { it.name })
    }

    @Test
    fun `lectura con huella separa la huella del contenido`() {
        val snapshot = assertNotNull(ProjectsFileCommands.parseSnapshot("123 45\n{\"a\":1}\n"))
        assertEquals("123 45", snapshot.fingerprint)
        assertEquals("{\"a\":1}\n", snapshot.text)
        assertEquals(ProjectsFileCommands.Snapshot("absent", ""), ProjectsFileCommands.parseSnapshot("absent\n"))
        assertEquals(null, ProjectsFileCommands.parseSnapshot(""))
    }

    /** Los comandos se ejecutan de verdad con `/bin/sh` en un `HOME` temporal. */
    @Test
    fun `solo se reemplaza el archivo si no cambio desde que se leyo`(@TempDir home: Path) {
        val file = home.resolve(ProjectCommands.PROJECTS_RELATIVE_PATH)
        val temp = home.resolve(ProjectCommands.PROJECTS_RELATIVE_PATH + RemoteHomeFileCommands.TEMP_SUFFIX)
        file.parent.createDirectories()

        // No existe: huella «absent» y se crea.
        val absent = assertNotNull(ProjectsFileCommands.parseSnapshot(sh(home, ProjectsFileCommands.READ_WITH_FINGERPRINT).second))
        assertEquals(ProjectsFileCommands.ABSENT, absent.fingerprint)
        temp.writeText("uno")
        assertEquals(0, sh(home, ProjectsFileCommands.commitIfUnchanged(absent.fingerprint)).first)
        assertEquals("uno", file.readText())

        // Existe y nadie lo tocó: se reemplaza.
        val first = assertNotNull(ProjectsFileCommands.parseSnapshot(sh(home, ProjectsFileCommands.READ_WITH_FINGERPRINT).second))
        assertEquals("uno", first.text)
        temp.writeText("dos")
        assertEquals(0, sh(home, ProjectsFileCommands.commitIfUnchanged(first.fingerprint)).first)
        assertEquals("dos", file.readText())

        // Otro lo cambió entretanto: no se toca y se borra el temporal.
        file.writeText("de otro dispositivo")
        temp.writeText("tres")
        assertEquals(ProjectsFileCommands.CHANGED_EXIT_CODE, sh(home, ProjectsFileCommands.commitIfUnchanged(first.fingerprint)).first)
        assertEquals("de otro dispositivo", file.readText())
        assertFalse(temp.exists())
        // Con la huella vieja de «no existe» tampoco se pisa un archivo creado por otro.
        temp.writeText("cuatro")
        assertEquals(ProjectsFileCommands.CHANGED_EXIT_CODE, sh(home, ProjectsFileCommands.commitIfUnchanged(ProjectsFileCommands.ABSENT)).first)
    }

    private fun sh(home: Path, command: String): Pair<Int, String> {
        val process = ProcessBuilder("/bin/sh", "-c", command)
            .apply { environment()["HOME"] = home.toString() }
            .start()
        val output = process.inputStream.bufferedReader().readText()
        return process.waitFor() to output
    }
}
