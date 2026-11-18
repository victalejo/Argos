@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.background

import com.iaportafolio.argos.core.github.CIResult
import com.iaportafolio.argos.core.github.CIWatch
import com.iaportafolio.argos.core.github.GitHubCheckState
import com.iaportafolio.argos.core.github.GitHubRun
import com.iaportafolio.argos.core.github.GitHubSnapshot
import com.iaportafolio.argos.core.github.GitHubStatusResult
import com.iaportafolio.argos.testing.FakeGitService
import com.iaportafolio.argos.testing.InMemoryAgentWatchBackend
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.SingleServiceProvider
import com.iaportafolio.argos.testing.server
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CIWatchServiceTest {

    private val dispatcher = StandardTestDispatcher()
    private val backend = InMemoryAgentWatchBackend()
    private val repository = InMemoryServerRepository(listOf(server()))
    private val git = FakeGitService()
    private val posted = mutableListOf<CIResult>()
    private var visible = true
    private var changes = 0
    private val now = Instant.parse("2026-11-18T12:00:00Z")

    private fun TestScope.service(provider: SingleServiceProvider = SingleServiceProvider(git)) = CIWatchService(
        servers = repository,
        services = provider,
        alerts = { _, _, result -> posted += result },
        scope = backgroundScope,
        io = dispatcher,
        clock = { now },
        store = CIWatchStore(backend),
        isVisible = { visible },
        onWatchesChanged = { changes++ },
    )

    private fun snapshot(state: GitHubCheckState) = GitHubStatusResult.Loaded(
        GitHubSnapshot("abc1234def", "main", null, listOf(GitHubRun(1, "ci", "", state, null, "push", null)), null),
    )

    @Test
    fun `lo vigilado se guarda y otro proceso lo recupera`() = runTest(dispatcher) {
        visible = false
        service().watch("S1", "/srv/app", "app", sha = "abc1234def")
        assertTrue(changes > 0)

        val restored = CIWatchStore(backend).load()
        assertEquals(mapOf("S1" to mapOf("/srv/app" to CIWatch("/srv/app", "app", "abc1234def", now))), restored)
        assertEquals(1, service().watchCountFlow.value)
    }

    @Test
    fun `oculta no consulta y el worker sí, con su proveedor, y avisa`() = runTest(dispatcher) {
        visible = false
        git.gitHubStatus = snapshot(GitHubCheckState.PENDING)
        val ci = service()
        ci.watch("S1", "/srv/app", "app", sha = "abc1234def")
        advanceTimeBy(120_000)
        assertTrue(git.gitHubStatusRequests.isEmpty())

        // Un proceso nuevo (el del worker) parte de lo guardado.
        git.gitHubStatus = snapshot(GitHubCheckState.FAILURE)
        val worker = service()
        worker.pollWith(SingleServiceProvider(git))
        runCurrent()

        assertEquals(listOf("/srv/app"), git.gitHubStatusRequests)
        assertEquals(1, posted.size)
        assertTrue(CIWatchStore(backend).load().isEmpty())
        assertEquals(0, worker.watchCountFlow.value)
    }

    @Test
    fun `un registro dañado se ignora`() {
        assertTrue(CIWatchStore(InMemoryAgentWatchBackend(mapOf("ci.watches" to "[nope"))).load().isEmpty())
    }
}
