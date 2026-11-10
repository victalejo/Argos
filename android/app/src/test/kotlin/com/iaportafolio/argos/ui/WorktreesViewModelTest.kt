@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.git.GitWorktreeParser
import com.iaportafolio.argos.testing.FakeGitService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryProjectPreferences
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.project
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.session
import com.iaportafolio.argos.ui.projects.WorktreesViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** «Ramas en paralelo» (paridad con la suite «Worktrees como proyectos» de Apple). */
class WorktreesViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val base = FakeSSHService()
    private val git = FakeGitService(base)
    private val parent = project(1, "app", path = "/srv/app", group = "web", startupCommand = "claude")

    private val listingOutput = """
        ARGOS_WT:list
        worktree /srv/app
        HEAD 1111111
        branch refs/heads/main

        worktree /srv/app-worktrees/feat-login
        HEAD 2222222
        branch refs/heads/feat/login

        ARGOS_WT:end
        ARGOS_WT:dirty 0 /srv/app
        ARGOS_WT:dirty 4 /srv/app-worktrees/feat-login
        ARGOS_WT:branch feat/login
        ARGOS_WT:branch fix/x
        ARGOS_WT:branch main
    """.trimIndent()

    private fun TestScope.loaded(projectId: String = parent.id): WorktreesViewModel {
        git.worktreeListing = GitWorktreeParser.parseList(listingOutput)
        return WorktreesViewModel(
            "S1",
            projectId,
            InMemoryServerRepository(listOf(server())),
            SingleServiceProvider(git),
            InMemoryProjectPreferences(),
            main.dispatcher,
        ).also { advanceUntilIdle() }
    }

    @Test
    fun `crear hereda grupo y comando, guarda la ruta real y arranca su sesión`() = runTest(main.dispatcher) {
        base.projects = listOf(parent)
        git.addedWorktreePath = "/real/app-worktrees/fix-x"
        val vm = loaded()
        vm.onCreatesBranch(false)
        vm.onBranch("fix/x")
        assertEquals("/srv/app-worktrees/fix-x", vm.state.value.path)
        assertEquals("app-fix-x", vm.state.value.projectName)
        assertTrue(vm.state.value.canCreate)
        vm.create()
        advanceUntilIdle()
        assertEquals(listOf("fix/x"), git.addedWorktrees.map { it.branch })
        val created = assertNotNull(base.projects.firstOrNull { it.name == "app-fix-x" })
        assertEquals("/real/app-worktrees/fix-x", created.path)
        assertEquals("web", created.group)
        assertEquals("claude", created.startupCommand)
        assertTrue(base.calls.any { it.startsWith("start:web/app-fix-x|/real/app-worktrees/fix-x") }, "${base.calls}")
        assertEquals("", vm.state.value.branch)
    }

    @Test
    fun `un nombre repetido se rechaza antes de crear el worktree`() = runTest(main.dispatcher) {
        base.projects = listOf(parent, project(2, "app-nueva", path = "/otra", group = "web"))
        val vm = loaded()
        vm.onBranch("nueva")
        vm.create()
        advanceUntilIdle()
        assertTrue(git.addedWorktrees.isEmpty())
        assertNotNull(vm.state.value.message)
    }

    @Test
    fun `la carpeta sigue a la rama hasta que el usuario la cambia`() = runTest(main.dispatcher) {
        base.projects = listOf(parent)
        val vm = loaded()
        vm.onBranch("a")
        assertEquals("/srv/app-worktrees/a", vm.state.value.path)
        vm.onPath("/otra/carpeta")
        vm.onBranch("b")
        assertEquals("/otra/carpeta", vm.state.value.path)
    }

    @Test
    fun `quitar detiene la sesión, quita el worktree forzado si hay cambios y su proyecto`() = runTest(main.dispatcher) {
        val worktreeProject = project(3, "app-feat-login", path = "/srv/app-worktrees/feat-login/", group = "web")
        base.projects = listOf(parent, worktreeProject)
        base.sessions = listOf(session("web/app-feat-login"))
        val vm = loaded()
        val worktree = assertNotNull(vm.state.value.listing?.worktrees?.firstOrNull { it.branch == "feat/login" })
        assertEquals(worktreeProject.id, vm.state.value.projectFor(worktree)?.id)
        vm.requestRemoval(worktree)
        vm.confirmRemoval()
        advanceUntilIdle()
        assertTrue(base.calls.any { it.startsWith("stop") && "web/app-feat-login" in it }, "${base.calls}")
        assertEquals(listOf("/srv/app-worktrees/feat-login" to true), git.removedWorktrees)
        assertFalse(base.projects.any { it.id == worktreeProject.id })
    }

    @Test
    fun `abierta desde un worktree, la rama nueva hereda del proyecto principal`() = runTest(main.dispatcher) {
        val fromWorktree = project(3, "app-feat-login", path = "/srv/app-worktrees/feat-login", group = "web")
        base.projects = listOf(parent, fromWorktree)
        val vm = loaded(fromWorktree.id)
        vm.onBranch("otra")
        assertEquals("app-otra", vm.state.value.projectName)
    }
}
