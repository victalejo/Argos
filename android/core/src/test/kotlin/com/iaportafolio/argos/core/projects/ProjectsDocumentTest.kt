package com.iaportafolio.argos.core.projects

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
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
    fun `un proyecto invalido no invalida el resto y se conserva al final`() {
        val broken = """{"id":"no-es-uuid","name":"roto"}"""
        val document = ProjectsDocument.decode(fileWith(json(project(1)), broken, "42", json(project(2))))
        assertEquals(listOf("p1", "p2"), document.projects.map { it.name })

        val withoutFirst = document.applying(document.projects, listOf(project(2), project(3)))
        val rewritten = ProjectsDocument.decode(withoutFirst.encodedText())
        assertEquals(listOf("p2", "p3"), rewritten.projects.map { it.name })
        val raw = rewritten.entries.filterIsInstance<ProjectRecord.Unreadable>().map { it.raw.toString() }
        assertEquals(listOf(broken, "42"), raw)
        // Como Apple: los ilegibles van detrás de los legibles, en su orden original.
        assertIs<ProjectRecord.Unreadable>(rewritten.entries[2])
        assertIs<ProjectRecord.Unreadable>(rewritten.entries[3])
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
    fun `las claves desconocidas de macCheckout sobreviven y quitarlo lo quita entero`() {
        val checkout = ""","macCheckout":{"date":"2025-11-07T10:00:00Z","macID":"x","macName":"M","rama":"main"}"""
        val document = ProjectsDocument.decode(fileWith(json(project(1), extra = ""","color":"verde"""" + checkout)))
        val renamed = document.projects.map { it.copy(name = "uno") }
        val entry = assertIs<ProjectRecord.Readable>(ProjectsDocument.decode(document.applying(document.projects, renamed).encodedText()).entries.single())
        assertEquals(JsonPrimitive("main"), entry.raw["macCheckout"]?.jsonObject?.get("rama"))
        assertEquals(JsonPrimitive("verde"), entry.raw["color"])

        val cleared = document.applying(document.projects, document.projects.map { it.copy(macCheckout = null) })
        val clearedEntry = assertIs<ProjectRecord.Readable>(ProjectsDocument.decode(cleared.encodedText()).entries.single())
        assertNull(clearedEntry.raw["macCheckout"])
        assertEquals(JsonPrimitive("verde"), clearedEntry.raw["color"])
    }

    /**
     * Bytes idénticos a los de `ProjectsDocument.swift` (generados con el código Swift real, ver
     * `swift-golden/projects-document-*.txt`) para los mismos datos de entrada.
     */
    @Test
    fun `mismos bytes que Swift al reescribir con desconocidos e ilegibles`() {
        val input = golden("projects-document-input")
        val document = ProjectsDocument.decode(input)
        val updated = document.projects.map { if (it.name == "uno") it.copy(name = "uno-renombrado", group = null) else it }
            .filterNot { it.name == "tres" } + Project(
            id = "55555555-5555-5555-5555-555555555555",
            name = "nuevo",
            path = "/srv/nuevo",
            createdAt = Instant.ofEpochSecond(1_762_509_600),
        )
        assertEquals(golden("projects-document-output"), document.applying(document.projects, updated).encodedText())
    }

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)
}
