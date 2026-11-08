package com.iaportafolio.argos.core.projects

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/**
 * `projects.json`: compatibilidad BYTE A BYTE con el `JSONEncoder` de Apple. [SWIFT_GOLDEN] es
 * la salida real de Swift 6.4 (mismo `Codable` y opciones que `ProjectsFile.encoded()`).
 */
class ProjectsFileTest {

    private val coro = Project(
        id = "6F1C2A3B-0000-4000-8000-000000000001",
        name = "coro",
        group = "ia portafolio",
        path = "/home/v/coro",
        startupCommand = "",
        // .750: Apple trunca las fracciones de segundo al escribir.
        createdAt = Instant.ofEpochMilli(1_762_509_600_750),
        macCheckout = MacCheckout("MacBook de Víctor \"VA\"", "abc-123", Instant.ofEpochSecond(1_762_513_200)),
    )

    private val roomies = Project(
        id = "6F1C2A3B-0000-4000-8000-000000000002",
        name = "roomies",
        path = "/srv/a b/ñ\\x\n\t\u0001é😀",
        createdAt = Instant.EPOCH,
    )

    @Test
    fun `codificar produce exactamente los bytes de Swift`() {
        val file = ProjectsFile(projects = listOf(coro, roomies))
        assertEquals(SWIFT_GOLDEN, file.encodedText())
        assertContentEquals(SWIFT_GOLDEN.toByteArray(Charsets.UTF_8), file.encoded())
    }

    @Test
    fun `fichero vacio se codifica como Swift`() {
        assertEquals(SWIFT_EMPTY, ProjectsFile.EMPTY.encodedText())
    }

    @Test
    fun `decodifica el json tal como lo escribe Swift`() {
        val decoded = ProjectsFile.decode(SWIFT_GOLDEN)
        assertEquals(1, decoded.version)
        assertEquals(listOf(coro.copy(createdAt = Instant.ofEpochSecond(1_762_509_600)), roomies), decoded.projects)
        assertEquals("ia portafolio/coro", decoded.projects[0].sessionName)
        assertEquals("", decoded.projects[0].startupCommand)
        assertNull(decoded.projects[1].group)
        assertNull(decoded.projects[1].macCheckout)
    }

    @Test
    fun `ida y vuelta conserva los proyectos y los bytes`() {
        val file = ProjectsFile(projects = listOf(Project(name = "coro", group = "ia", path = "/c", startupCommand = "")))
        val decoded = ProjectsFile.decode(file.encodedText())
        assertEquals(listOf("ia/coro"), decoded.projects.map { it.sessionName })
        assertEquals("", decoded.projects[0].startupCommand)
        assertEquals(file.encodedText(), decoded.encodedText())
        assertEquals(SWIFT_GOLDEN, ProjectsFile.decode(SWIFT_GOLDEN).encodedText())
    }

    @Test
    fun `vacio es sin proyectos e invalido lanza invalidFile`() {
        assertEquals(ProjectsFile.EMPTY, ProjectsFile.decode(""))
        assertEquals(ProjectsFile.EMPTY, ProjectsFile.decode("  \n"))
        assertEquals(ProjectError.InvalidFile, assertFailsWith<ProjectError> { ProjectsFile.decode("{ roto") })
    }

    @Test
    fun `como Apple exige version, id y createdAt`() {
        assertFailsWith<ProjectError.InvalidFile> { ProjectsFile.decode("""{"projects":[]}""") }
        assertFailsWith<ProjectError.InvalidFile> {
            ProjectsFile.decode("""{"version":1,"projects":[{"name":"a","path":"/a","createdAt":"2025-01-01T00:00:00Z"}]}""")
        }
        assertFailsWith<ProjectError.InvalidFile> {
            ProjectsFile.decode("""{"version":1,"projects":[{"id":"6F1C2A3B-0000-4000-8000-000000000001","name":"a","path":"/a"}]}""")
        }
        assertFailsWith<ProjectError.InvalidFile> {
            ProjectsFile.decode("""{"version":1,"projects":[{"id":"zz","name":"a","path":"/a","createdAt":"2025-01-01T00:00:00Z"}]}""")
        }
    }

    @Test
    fun `como Apple tolera claves desconocidas, null, fracciones, desfases y uuid en minusculas`() {
        val json = """{"version":1,"extra":true,"projects":[""" +
            """{"id":"6f1c2a3b-0000-4000-8000-00000000000a","name":"a","path":"/a","group":null,"x":5,"createdAt":"2025-01-01T00:00:00.5Z"},""" +
            """{"id":"6F1C2A3B-0000-4000-8000-00000000000B","name":"b","path":"/b","createdAt":"2025-01-01T02:00:00+02:00"},""" +
            """{"id":"6F1C2A3B-0000-4000-8000-00000000000C","name":"c","path":"/c","createdAt":"2025-01-01T00:00:00z"}]}"""
        val projects = ProjectsFile.decode(json).projects
        assertEquals("6F1C2A3B-0000-4000-8000-00000000000A", projects[0].id)
        assertNull(projects[0].group)
        assertEquals(Instant.parse("2025-01-01T00:00:00.5Z"), projects[0].createdAt)
        assertEquals(Instant.parse("2025-01-01T00:00:00Z"), projects[1].createdAt)
        assertEquals(Instant.parse("2025-01-01T00:00:00Z"), projects[2].createdAt)
    }

    private companion object {
        val SWIFT_GOLDEN = """
            {
              "projects" : [
                {
                  "createdAt" : "2025-11-07T10:00:00Z",
                  "group" : "ia portafolio",
                  "id" : "6F1C2A3B-0000-4000-8000-000000000001",
                  "macCheckout" : {
                    "date" : "2025-11-07T11:00:00Z",
                    "macID" : "abc-123",
                    "macName" : "MacBook de Víctor \"VA\""
                  },
                  "name" : "coro",
                  "path" : "/home/v/coro",
                  "startupCommand" : ""
                },
                {
                  "createdAt" : "1970-01-01T00:00:00Z",
                  "id" : "6F1C2A3B-0000-4000-8000-000000000002",
                  "name" : "roomies",
                  "path" : "/srv/a b/ñ\\x\n\t\u0001é😀"
                }
              ],
              "version" : 1
            }
        """.trimIndent()

        val SWIFT_EMPTY = "{\n  \"projects\" : [\n\n  ],\n  \"version\" : 1\n}"
    }
}
