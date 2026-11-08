package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.tmux.SessionGrouping
import com.iaportafolio.argos.core.tmux.SessionNameValidator
import com.iaportafolio.argos.core.tmux.TmuxSession
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Proyectos anclados a carpeta (port de `ProjectTests.swift`). */
class ProjectTest {

    private fun session(name: String) = TmuxSession(name, 1, false, Instant.EPOCH)

    // Identidad y comando

    @Test
    fun `el nombre de sesion es grupo-nombre, o nombre sin grupo`() {
        assertEquals("ia portafolio/coro", Project(name = "coro", group = "ia portafolio", path = "/x").sessionName)
        assertEquals("roomies", Project(name = "roomies", path = "/x").sessionName)
        assertEquals("roomies", Project(name = "roomies", group = "", path = "/x").sessionName)
    }

    @Test
    fun `comando de arranque - null usa el predeterminado, vacio no lanza nada`() {
        assertEquals("cc --continue", Project(name = "a", path = "/x").resolvedStartupCommand("cc --continue"))
        assertEquals("npm run dev", Project(name = "a", path = "/x", startupCommand = "npm run dev").resolvedStartupCommand("cc"))
        assertNull(Project(name = "a", path = "/x", startupCommand = "  ").resolvedStartupCommand("cc"))
        assertNull(Project(name = "a", path = "/x").resolvedStartupCommand(""))
    }

    @Test
    fun `los ids nuevos son UUID en mayusculas como en Apple`() {
        val id = Project(name = "a", path = "/x").id
        assertEquals(id.uppercase(), id)
        assertEquals(36, id.length)
    }

    // Cruce con sesiones

    @Test
    fun `proyectos con sesion corren, sin sesion estan detenidos y el resto son sueltas`() {
        val coro = Project(name = "coro", group = "ia", path = "/c")
        val vetto = Project(name = "vetto", group = "ia", path = "/v")
        val (entries, loose) = ProjectListing.build(
            projects = listOf(vetto, coro),
            sessions = listOf(session("ia/coro"), session("suelta"), session("ia/vetto-2")),
        )
        assertEquals(listOf("coro", "vetto"), entries.map { it.project.name })
        assertTrue(entries[0].isRunning)
        assertFalse(entries[1].isRunning)
        assertEquals(listOf("ia/vetto-2", "suelta"), loose.map { it.name })
    }

    @Test
    fun `el orden por nombre es natural como localizedStandardCompare`() {
        val projects = listOf("web10", "Web2", "api").map { Project(name = it, path = "/x") }
        assertEquals(listOf("api", "Web2", "web10"), ProjectListing.build(projects, emptyList()).entries.map { it.project.name })
    }

    @Test
    fun `grupos ordenados con General al final`() {
        val entries = listOf(
            ProjectEntry(Project(name = "a", path = "/a"), null),
            ProjectEntry(Project(name = "b", group = "tmh", path = "/b"), null),
            ProjectEntry(Project(name = "c", group = "ia", path = "/c"), null),
        )
        assertEquals(listOf("ia", "tmh", SessionGrouping.UNGROUPED_NAME), ProjectListing.groups(entries).map { it.name })
    }

    // Importación

    @Test
    fun `importar conserva el nombre de sesion exacto`() {
        val grouped = assertNotNull(ProjectListing.importCandidate(session("ia portafolio/coro"), "/home/v/coro"))
        assertEquals("ia portafolio", grouped.group)
        assertEquals("coro", grouped.name)
        assertEquals("ia portafolio/coro", grouped.sessionName)
        assertNull(grouped.startupCommand)

        val plain = assertNotNull(ProjectListing.importCandidate(session("roomies"), "/r"))
        assertNull(plain.group)
        assertEquals("roomies", plain.sessionName)

        val odd = assertNotNull(ProjectListing.importCandidate(session("foo/"), "/f"))
        assertEquals("foo/", odd.sessionName)
    }

    @Test
    fun `sin ruta absoluta no hay candidato`() {
        assertNull(ProjectListing.importCandidate(session("x"), null))
        assertNull(ProjectListing.importCandidate(session("x"), "relativa"))
    }

    @Test
    fun `ruta del primer panel de cada sesion, menor ventana y panel`() {
        val output = """
            2|1|/b|ia/coro
            1|2|/c|ia/coro
            1|1|/a|ia/coro
            1|1|/r|real bros|x
        """.trimIndent()
        val paths = ProjectListing.firstPanePaths(output)
        assertEquals("/a", paths["ia/coro"])
        assertEquals("/r", paths["real bros|x"])
    }

    // Validación

    @Test
    fun `valida nombre, grupo, ruta absoluta y unicidad`() {
        val existing = Project(name = "coro", group = "ia", path = "/c")
        val ok = ProjectListing.validate(Project(name = "  vetto ", group = " ia ", path = " /v "), listOf(existing), emptyList())
        assertEquals("vetto", ok.name)
        assertEquals("ia", ok.group)
        assertEquals("/v", ok.path)

        assertEquals(
            ProjectError.DuplicateName("ia/coro"),
            assertFailsWith<ProjectError> { ProjectListing.validate(Project(name = "coro", group = "ia", path = "/x"), listOf(existing), emptyList()) },
        )
        assertEquals(
            ProjectError.DuplicateName("suelta"),
            assertFailsWith<ProjectError> { ProjectListing.validate(Project(name = "suelta", path = "/x"), emptyList(), listOf(session("suelta"))) },
        )
        assertEquals(
            ProjectError.InvalidPath,
            assertFailsWith<ProjectError> { ProjectListing.validate(Project(name = "x", path = "~/x"), emptyList(), emptyList()) },
        )
        assertFailsWith<SessionNameValidator.ValidationError.ForbiddenCharacter> {
            ProjectListing.validate(Project(name = "a/b", path = "/x"), emptyList(), emptyList())
        }
        assertFailsWith<SessionNameValidator.ValidationError.ForbiddenCharacter> {
            ProjectListing.validate(Project(name = "a", group = "x/y", path = "/x"), emptyList(), emptyList())
        }
    }

    @Test
    fun `un grupo solo de espacios se normaliza a sin grupo`() {
        assertNull(ProjectListing.validate(Project(name = "a", group = "  ", path = "/x"), emptyList(), emptyList()).group)
    }

    @Test
    fun `editar un proyecto no choca consigo mismo`() {
        val existing = Project(name = "coro", group = "ia", path = "/c")
        val edited = existing.copy(path = "/nueva")
        assertEquals("/nueva", ProjectListing.validate(edited, listOf(existing), emptyList()).path)
    }

    // Ajustes (la persistencia es de plataforma; aquí solo las constantes)

    @Test
    fun `ajuste global - predeterminado de fabrica y atajos`() {
        assertEquals("cc --continue", ProjectDefaults.FACTORY_STARTUP_COMMAND)
        assertEquals(listOf("cc --continue", "cc", "claude --continue", ""), ProjectDefaults.PRESETS.map { it.command })
    }
}
