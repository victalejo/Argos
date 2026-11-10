@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.background.CIWatchService
import com.iaportafolio.argos.core.git.GitBranchInfo
import com.iaportafolio.argos.core.github.CIResult
import com.iaportafolio.argos.core.github.CIWatcher
import com.iaportafolio.argos.core.github.GitHubCheckState
import com.iaportafolio.argos.core.github.GitHubRepositoriesResult
import com.iaportafolio.argos.core.github.GitHubRepository
import com.iaportafolio.argos.core.github.GitHubRun
import com.iaportafolio.argos.core.github.GitHubSnapshot
import com.iaportafolio.argos.core.github.GitHubStatusResult
import com.iaportafolio.argos.testing.FakeGitService
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.InMemoryProjectPreferences
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.gitStatus
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.git.GitChangesViewModel
import com.iaportafolio.argos.ui.git.GitHubLoad
import com.iaportafolio.argos.ui.git.GitHubViewModel
import com.iaportafolio.argos.ui.projects.CloneRepositories
import com.iaportafolio.argos.ui.projects.ProjectsDialog
import com.iaportafolio.argos.ui.projects.ProjectsViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun snapshot(vararg runs: Pair<String, GitHubCheckState>) = GitHubStatusResult.Loaded(
    GitHubSnapshot(
        "abc",
        "main",
        null,
        runs.mapIndexed { index, (workflow, state) -> GitHubRun(index.toLong() + 5, workflow, "", state, null, "push", null) },
        null,
    ),
)

private val upToDate = GitBranchInfo("main", "origin/main", 0, 0, hasCommits = true, upstreamGone = false)

/** Sección GitHub de «Cambios» (paridad con la suite `GitHubStatusModel` de Apple). */
class GitHubViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val git = FakeGitService()
    private var now: Instant = Instant.ofEpochSecond(1_800_000_000)
    private val pending = mutableListOf<String>()

    private fun TestScope.loaded() = GitHubViewModel(
        "S1",
        "/r",
        InMemoryServerRepository(listOf(server())),
        SingleServiceProvider(git),
        main.dispatcher,
        onCIPending = { pending += it },
        clock = { now },
    ).also {
        it.refresh(force = true)
        advanceUntilIdle()
    }

    @Test
    fun `espacia las lecturas, más a menudo con CI en curso, y avisa del CI en curso`() = runTest(main.dispatcher) {
        git.gitHubStatus = snapshot("CI" to GitHubCheckState.FAILURE, "Android" to GitHubCheckState.PENDING)
        val vm = loaded()
        assertEquals(listOf("abc"), pending)
        now = now.plusSeconds(5)
        vm.refresh()
        advanceUntilIdle()
        assertEquals(1, git.gitHubStatusRequests.size)
        now = now + GitHubViewModel.PENDING_INTERVAL
        vm.refresh()
        advanceUntilIdle()
        assertEquals(2, git.gitHubStatusRequests.size)
        assertTrue(vm.state.value.isPending)
    }

    @Test
    fun `crear PR solo con la rama subida y relanzar refresca`() = runTest(main.dispatcher) {
        git.gitHubStatus = snapshot("CI" to GitHubCheckState.FAILURE)
        val vm = loaded()
        assertTrue(vm.state.value.canCreatePullRequest(upToDate))
        assertFalse(vm.state.value.canCreatePullRequest(upToDate.copy(ahead = 1)))
        assertFalse(vm.state.value.canCreatePullRequest(upToDate.copy(upstream = null)))
        vm.createPullRequest(draft = true)
        advanceUntilIdle()
        assertEquals(listOf(true), git.createdPullRequests)
        assertEquals(UiText.res(R.string.github_pr_created_url, "https://github.com/o/r/pull/7"), vm.state.value.message)
        val failed = assertNotNull(vm.state.value.snapshot?.failedRuns?.firstOrNull())
        vm.rerunFailed(failed)
        advanceUntilIdle()
        assertEquals(listOf(5L), git.reruns)
        assertEquals(3, git.gitHubStatusRequests.size)
    }

    @Test
    fun `un fallo con datos visibles no los borra y sin GitHub se oculta`() = runTest(main.dispatcher) {
        git.gitHubStatus = snapshot("CI" to GitHubCheckState.SUCCESS)
        val vm = loaded()
        git.gitHubStatus = GitHubStatusResult.Failed("HTTP 502")
        vm.refresh(force = true)
        advanceUntilIdle()
        assertNotNull(vm.state.value.snapshot)
        git.gitHubStatus = GitHubStatusResult.NotGitHub
        vm.refresh(force = true)
        advanceUntilIdle()
        assertEquals(GitHubLoad.NotGitHub, vm.state.value.load)
    }
}

/** Avisos del CI de lo subido (paridad con «SessionsViewModel: CI vigilado»). */
class CIWatchServiceTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val git = FakeGitService()
    private var now: Instant = Instant.ofEpochSecond(1_800_000_000)
    private val posted = mutableListOf<Pair<String, CIResult>>()

    private fun TestScope.service() = CIWatchService(
        InMemoryServerRepository(listOf(server())),
        SingleServiceProvider(git),
        { _, serverName, result -> posted += serverName to result },
        backgroundScope,
        main.dispatcher,
        clock = { now },
    )

    @Test
    fun `avisa una vez al terminar el CI de lo subido y deja de vigilarlo`() = runTest(main.dispatcher) {
        git.gitHubStatus = snapshot("CI" to GitHubCheckState.PENDING)
        val ci = service()
        ci.watch("S1", "/srv/app", "app", sha = null)
        ci.pollOnce()
        assertTrue(ci.isWatching)
        git.gitHubStatus = snapshot("CI" to GitHubCheckState.SUCCESS)
        now = now + CIWatcher.POLL_INTERVAL
        ci.pollOnce()
        assertEquals(listOf("dev" to "CI de «app»: pasó"), posted.map { it.first to it.second.title })
        assertFalse(ci.isWatching)
        assertEquals(listOf("/srv/app", "/srv/app"), git.gitHubStatusRequests)
    }

    @Test
    fun `respeta el intervalo entre lecturas y un fallo de red se reintenta`() = runTest(main.dispatcher) {
        git.gitHubError = java.io.IOException("red")
        val ci = service()
        ci.watch("S1", "/srv/app", "app", sha = "abc")
        ci.pollOnce()
        ci.pollOnce()
        assertEquals(1, git.gitHubStatusRequests.size)
        assertTrue(ci.isWatching)
    }

    @Test
    fun `el push de Cambios empieza a vigilar el CI`() = runTest(main.dispatcher) {
        git.statusResult = gitStatus(emptyList(), ahead = 2)
        val pushed = mutableListOf<String>()
        val vm = GitChangesViewModel("S1", "/r", InMemoryServerRepository(listOf(server())), SingleServiceProvider(git), main.dispatcher) {
            pushed += it
        }
        advanceUntilIdle()
        vm.push()
        advanceUntilIdle()
        assertEquals(listOf("/r"), pushed)
    }
}

/** «Clonar de GitHub» del formulario de nuevo proyecto (paridad con `GitHubCloneModel`). */
class ProjectCloneTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val base = FakeSSHService()
    private val git = FakeGitService(base)

    private fun TestScope.loaded() = ProjectsViewModel(
        "S1",
        InMemoryServerRepository(listOf(server())),
        SingleServiceProvider(git),
        InMemoryTrustStore(),
        InMemoryProjectPreferences(),
        main.dispatcher,
    ).also { advanceUntilIdle() }

    private fun ProjectsViewModel.clone() = assertNotNull(assertIs<ProjectsDialog.Form>(state.value.dialog).form.clone)

    @Test
    fun `carga tus repos, la carpeta y el nombre siguen al repo y clona antes de guardar`() = runTest(main.dispatcher) {
        val old = GitHubRepository("o/viejo", "", false, Instant.ofEpochSecond(1))
        val new = GitHubRepository("o/nuevo", "", true, Instant.ofEpochSecond(9))
        git.repositories = GitHubRepositoriesResult.Loaded(listOf(old, new))
        val vm = loaded()
        vm.openNewProject()
        vm.onFormClone(true)
        advanceUntilIdle()
        assertEquals(CloneRepositories.Loaded(listOf(new, old)), vm.clone().repositories)

        vm.onCloneChoose(new)
        vm.onCloneParent("/srv")
        assertEquals("nuevo", vm.clone().folder)
        assertEquals("nuevo", assertIs<ProjectsDialog.Form>(vm.state.value.dialog).form.name)
        vm.onCloneFolder("mio")
        vm.onCloneRepository("o/otro")
        assertEquals("mio", vm.clone().folder)
        assertTrue(assertIs<ProjectsDialog.Form>(vm.state.value.dialog).form.canSubmit)

        vm.submitForm()
        advanceUntilIdle()
        assertEquals(listOf("o/otro"), git.cloneRequests.map { it.repository })
        assertNull(vm.state.value.dialog)
        assertEquals("/srv/clonado", base.projects.single().path)
    }

    @Test
    fun `repositorio no válido o sin gh, no se puede crear`() = runTest(main.dispatcher) {
        git.repositories = GitHubRepositoriesResult.NotAuthenticated
        val vm = loaded()
        vm.openNewProject()
        vm.onFormClone(true)
        advanceUntilIdle()
        assertEquals(CloneRepositories.NotAuthenticated, vm.clone().repositories)
        vm.onFormName("app")
        vm.onCloneRepository("-x/y")
        assertFalse(assertIs<ProjectsDialog.Form>(vm.state.value.dialog).form.canSubmit)
        vm.onFormClone(false)
        assertNull(assertIs<ProjectsDialog.Form>(vm.state.value.dialog).form.clone)
    }
}
