package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.SSHServiceError
import com.iaportafolio.argos.core.tmux.TmuxSession
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ciclo de vida de proyectos (port de `ProjectLifecycleTests.swift`), reexpresado sobre las
 * decisiones puras de [ProjectLifecycle] en lugar del ViewModel con `MockSSHService`.
 */
class ProjectLifecycleTest {

    private fun session(name: String) = TmuxSession(name, 1, false, Instant.EPOCH)

    @Test
    fun `abrir un proyecto detenido crea su sesion con el comando predeterminado`() {
        val coro = Project(name = "coro", group = "ia", path = "/srv/coro")
        assertEquals(false, ProjectListing.build(listOf(coro), emptyList()).entries.first().isRunning)

        val request = ProjectLifecycle.startRequest(coro, emptyList(), "cc --continue")
        assertEquals(ProjectLifecycle.StartRequest("ia/coro", "/srv/coro", "cc --continue"), request)
        // Con la sesión ya creada, el listado la ve corriendo.
        assertEquals(true, ProjectListing.build(listOf(coro), listOf(session("ia/coro"))).entries.first().isRunning)
    }

    @Test
    fun `abrir un proyecto que ya corre no crea otra sesion`() {
        val coro = Project(name = "coro", path = "/srv/coro")
        assertNull(ProjectLifecycle.startRequest(coro, listOf(session("coro")), "cc"))
    }

    @Test
    fun `comando vacio del proyecto no lanza nada`() {
        val web = Project(name = "web", path = "/w", startupCommand = "")
        assertNull(ProjectLifecycle.startRequest(web, emptyList(), "cc --continue")?.startupCommand)
        assertEquals(
            "[ -d '/w' ] || exit 3; tmux new-session -d -s 'web' -c '/w'",
            ProjectCommands.startProject("web", "/w", null),
        )
    }

    @Test
    fun `carpeta inexistente - error claro`() {
        assertEquals(ProjectError.MissingFolder("/borrada"), ProjectCommands.startProjectFailure(3, "", "/borrada"))
        assertNull(ProjectCommands.startProjectFailure(0, "", "/x"))
        val other = assertIs<SSHServiceError.CommandFailed>(ProjectCommands.startProjectFailure(1, "  duplicate session\n", "/x"))
        assertEquals("duplicate session", other.detail)
        val silent = assertIs<SSHServiceError.CommandFailed>(ProjectCommands.startProjectFailure(2, "", "/x"))
        assertEquals("No se pudo abrir el proyecto.", silent.detail)
    }

    @Test
    fun `detener mata la sesion pero conserva el proyecto`() {
        val coro = Project(name = "coro", path = "/srv/coro")
        assertEquals("tmux kill-session -t '=coro'", ProjectCommands.stopSession(coro.sessionName))
        // El proyecto sigue en la lista; sin su sesión pasa a detenido.
        assertEquals(false, ProjectListing.build(listOf(coro), emptyList()).entries.first().isRunning)
    }

    @Test
    fun `importar convierte sesiones sueltas en proyectos con su carpeta`() {
        val sessions = listOf(session("ia portafolio/coro"), session("roomies"))
        assertEquals(2, ProjectListing.build(emptyList(), sessions).looseSessions.size)

        val paths = mapOf("ia portafolio/coro" to "/home/v/coro", "roomies" to "/home/v/roomies")
        val candidates = ProjectLifecycle.importCandidates(emptyList(), sessions, paths)
        val stored = ProjectLifecycle.importing(emptyList(), candidates)

        assertEquals(setOf("ia portafolio/coro", "roomies"), stored.map { it.sessionName }.toSet())
        val listing = ProjectListing.build(stored, sessions)
        assertTrue(listing.looseSessions.isEmpty())
        assertTrue(listing.entries.all { it.isRunning })
    }

    @Test
    fun `importar no duplica proyectos con el mismo nombre de sesion`() {
        val existing = Project(name = "coro", path = "/a")
        val result = ProjectLifecycle.importing(listOf(existing), listOf(Project(name = "coro", path = "/b"), Project(name = "x", path = "/x")))
        assertEquals(listOf("/a", "/x"), result.map { it.path })
    }

    @Test
    fun `renombrar un proyecto en marcha renombra tambien su sesion tmux`() {
        val coro = Project(name = "coro", path = "/srv/coro")
        val plan = ProjectLifecycle.planSave(coro.copy(name = "coro-v2"), listOf(coro), listOf(session("coro")))
        assertEquals(ProjectLifecycle.SessionRename("coro", "coro-v2"), plan.rename)
        assertEquals(listOf("coro-v2"), ProjectLifecycle.upserting(listOf(coro), plan.project).map { it.name })
    }

    @Test
    fun `renombrar un proyecto detenido no toca tmux`() {
        val coro = Project(name = "coro", path = "/srv/coro")
        assertNull(ProjectLifecycle.planSave(coro.copy(name = "coro-v2"), listOf(coro), emptyList()).rename)
    }

    @Test
    fun `quitar un proyecto no mata su sesion - pasa a sesion suelta`() {
        val coro = Project(name = "coro", path = "/srv/coro")
        val remaining = ProjectLifecycle.removing(listOf(coro), coro.id)
        assertEquals(listOf("coro"), ProjectListing.build(remaining, listOf(session("coro"))).looseSessions.map { it.name })
    }

    @Test
    fun `convertir una sesion suelta en proyecto la adopta`() {
        val sessions = listOf(session("roomies"))
        val roomies = Project(name = "roomies", path = "/r")
        assertEquals(
            ProjectError.DuplicateName("roomies"),
            assertFailsWith<ProjectError> { ProjectLifecycle.planSave(roomies, emptyList(), sessions) },
        )
        val plan = ProjectLifecycle.planSave(roomies, emptyList(), sessions, adoptedSession = "roomies")
        val listing = ProjectListing.build(ProjectLifecycle.upserting(emptyList(), plan.project), sessions)
        assertEquals(true, listing.entries.first().isRunning)
        assertTrue(listing.looseSessions.isEmpty())
    }

    @Test
    fun `marcar y desmarcar el envio al Mac solo afecta a ese proyecto`() {
        val a = Project(name = "a", path = "/a")
        val b = Project(name = "b", path = "/b")
        val checkout = MacCheckout("Mac", "id-1", Instant.EPOCH)
        val marked = ProjectLifecycle.settingMacCheckout(listOf(a, b), a.id, checkout)
        assertEquals(listOf(checkout, null), marked.map { it.macCheckout })
        assertEquals(listOf(null, null), ProjectLifecycle.settingMacCheckout(marked, a.id, null).map { it.macCheckout })
    }

    @Test
    fun `proyecto por nombre de sesion`() {
        val coro = Project(name = "coro", group = "ia", path = "/c")
        assertEquals(coro, ProjectLifecycle.projectForSession("ia/coro", listOf(coro)))
        assertNull(ProjectLifecycle.projectForSession("coro", listOf(coro)))
    }
}
