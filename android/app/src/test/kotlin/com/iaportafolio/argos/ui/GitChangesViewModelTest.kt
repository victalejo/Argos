@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.git.GitBranchInfo
import com.iaportafolio.argos.core.git.GitCommandException
import com.iaportafolio.argos.core.git.GitDiffParser
import com.iaportafolio.argos.core.git.GitFileChange
import com.iaportafolio.argos.core.git.GitRepoSummary
import com.iaportafolio.argos.core.git.GitStatusResult
import com.iaportafolio.argos.testing.FakeGitService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryProjectPreferences
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.gitStatus
import com.iaportafolio.argos.testing.project
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.git.GitChangesUiState
import com.iaportafolio.argos.ui.git.GitChangesViewModel
import com.iaportafolio.argos.ui.git.GitDiffLoad
import com.iaportafolio.argos.ui.git.GitPanelLoad
import com.iaportafolio.argos.ui.projects.ProjectsViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Panel «Cambios» (paridad con la suite `GitChangesModel` de `GitTests.swift`). */
class GitChangesViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val git = FakeGitService()
    private val repository = InMemoryServerRepository(listOf(server()))

    private fun TestScope.loaded() =
        GitChangesViewModel("S1", "/r", repository, SingleServiceProvider(git), main.dispatcher).also { advanceUntilIdle() }

    private val modified = GitFileChange("a.txt", null, ' ', 'M')
    private val renamed = GitFileChange("new.txt", "old.txt", 'R', ' ')

    @Test
    fun `commit con las rutas incluidas y limpia el mensaje`() = runTest(main.dispatcher) {
        git.statusResult = gitStatus(listOf(modified, renamed))
        val vm = loaded()
        assertFalse(vm.state.value.canCommit)
        vm.onCommitMessage("  fix: algo \n")
        vm.setIncluded(modified, included = false)
        assertEquals(1, vm.state.value.includedCount)
        vm.commit()
        advanceUntilIdle()
        assertEquals(listOf("fix: algo" to listOf("old.txt", "new.txt")), git.commits)
        assertEquals("", vm.state.value.commitMessage)
        assertEquals(UiText.Plain("[main abc1234] fix: algo"), vm.state.value.message)
    }

    @Test
    fun `un commit fallido conserva el mensaje y muestra el error`() = runTest(main.dispatcher) {
        git.statusResult = gitStatus(listOf(modified))
        git.error = GitCommandException("fatal: Please tell me who you are.")
        val vm = loaded()
        vm.onCommitMessage("wip")
        vm.commit()
        advanceUntilIdle()
        assertEquals("wip", vm.state.value.commitMessage)
        assertEquals(UiText.Plain("fatal: Please tell me who you are."), vm.state.value.message)
        assertNull(vm.state.value.operation)
    }

    @Test
    fun `seleccionar carga el diff y desaparece si el archivo deja de cambiar`() = runTest(main.dispatcher) {
        git.statusResult = gitStatus(listOf(modified))
        git.diffResult = GitDiffParser.parse("@@ -1,2 +1,3 @@\n uno\n+dos\n+tres\n")
        val vm = loaded()
        vm.select("a.txt")
        advanceUntilIdle()
        assertEquals(modified, vm.state.value.selectedChange)
        assertEquals(2, assertIs<GitDiffLoad.Loaded>(vm.state.value.diff).diff.additions)

        git.statusResult = gitStatus(emptyList())
        vm.refresh(reloadDiff = false)
        advanceUntilIdle()
        assertNull(vm.state.value.selectedPath)
        assertEquals(GitDiffLoad.None, vm.state.value.diff)
    }

    @Test
    fun `el refresco automático no recarga el diff si el archivo no cambió`() = runTest(main.dispatcher) {
        git.statusResult = gitStatus(listOf(modified))
        val vm = loaded()
        vm.select("a.txt")
        advanceUntilIdle()
        vm.startPolling()
        advanceTimeBy(GitChangesViewModel.POLL_INTERVAL_MILLIS + 1)
        runCurrent()
        vm.stopPolling()
        assertEquals(1, git.diffRequests.size)
        vm.refresh()
        advanceUntilIdle()
        assertEquals(2, git.diffRequests.size)
    }

    @Test
    fun `push solo si hay algo que subir o no hay upstream`() = runTest(main.dispatcher) {
        git.statusResult = gitStatus(emptyList(), ahead = 0)
        val vm = loaded()
        assertFalse(vm.state.value.canPush)
        git.statusResult = gitStatus(emptyList(), ahead = 3)
        vm.refresh()
        advanceUntilIdle()
        assertTrue(vm.state.value.canPush)
        vm.push()
        advanceUntilIdle()
        assertEquals(listOf(true), git.pushes)
        assertEquals(UiText.res(R.string.git_push_done, "origin/main"), vm.state.value.message)
        git.statusResult = gitStatus(emptyList(), upstream = null)
        vm.refresh()
        advanceUntilIdle()
        assertTrue(vm.state.value.canPush)
        assertFalse(vm.state.value.canPull)
    }

    @Test
    fun `descartar pide confirmación y no se permite el commit con conflictos`() = runTest(main.dispatcher) {
        val conflict = GitFileChange("c", null, 'U', 'U')
        git.statusResult = gitStatus(listOf(modified, conflict))
        val vm = loaded()
        vm.onCommitMessage("x")
        assertTrue(vm.state.value.hasConflicts)
        assertFalse(vm.state.value.canCommit)
        vm.requestDiscard(modified)
        assertEquals(modified, vm.state.value.confirmDiscard)
        assertTrue(git.discarded.isEmpty())
        vm.confirmDiscard()
        advanceUntilIdle()
        assertEquals(listOf(modified), git.discarded)
        assertNull(vm.state.value.confirmDiscard)
    }

    @Test
    fun `estados sin repositorio y desmarcados que ya no existen`() = runTest(main.dispatcher) {
        val vm = loaded()
        assertEquals(GitPanelLoad.NotRepository, vm.state.value.load)
        git.statusResult = GitStatusResult.GitMissing
        vm.refresh()
        advanceUntilIdle()
        assertEquals(GitPanelLoad.GitMissing, vm.state.value.load)

        git.statusResult = gitStatus(listOf(modified, renamed))
        vm.refresh()
        advanceUntilIdle()
        vm.setAllIncluded(false)
        assertEquals(0, vm.state.value.includedCount)
        git.statusResult = gitStatus(listOf(renamed))
        vm.refresh()
        advanceUntilIdle()
        assertEquals(setOf("new.txt"), vm.state.value.excludedPaths)
    }

    @Test
    fun `rutas incluidas sin las desmarcadas`() {
        assertEquals(listOf(renamed), GitChangesUiState.includedChanges(listOf(renamed, modified), setOf("a.txt")))
    }
}

/** Insignia git de la lista de proyectos (paridad con «SessionsViewModel: resumen git»). */
class ProjectsGitSummaryTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val base = FakeSSHService()
    private val git = FakeGitService(base)
    private val api = project(1, "api", path = "/srv/app")

    private fun TestScope.loaded() = ProjectsViewModel(
        "S1",
        InMemoryServerRepository(listOf(server())),
        SingleServiceProvider(git),
        InMemoryTrustStore(),
        InMemoryProjectPreferences(),
        main.dispatcher,
    ).also { advanceUntilIdle() }

    @Test
    fun `una sola consulta para todos los proyectos, sin rutas repetidas`() = runTest(main.dispatcher) {
        base.projects = listOf(api, project(2, "api2", path = "/srv/app"))
        git.summaries = mapOf("/srv/app" to GitRepoSummary(GitBranchInfo.UNKNOWN, 3))
        val vm = loaded()
        assertEquals(listOf(listOf("/srv/app")), git.summaryRequests)
        assertEquals(3, vm.state.value.gitSummaries["/srv/app"]?.changedCount)
    }

    @Test
    fun `un fallo conserva el último resumen`() = runTest(main.dispatcher) {
        base.projects = listOf(api)
        git.summaries = mapOf("/srv/app" to GitRepoSummary(GitBranchInfo.UNKNOWN, 3))
        val vm = loaded()
        git.error = GitCommandException("red caída")
        vm.refresh()
        advanceUntilIdle()
        assertEquals(2, git.summaryRequests.size)
        assertEquals(3, vm.state.value.gitSummaries["/srv/app"]?.changedCount)
        assertNull(vm.state.value.message)
    }
}
