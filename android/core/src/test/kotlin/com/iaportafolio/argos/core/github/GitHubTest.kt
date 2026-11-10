package com.iaportafolio.argos.core.github

import java.time.Duration
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Comandos `gh` byte a byte con Swift (golden generados con `ArgosCore/GitHub/GitHubCommands.swift`). */
class GitHubParityGoldenTest {

    private fun golden(name: String): String =
        assertNotNull(javaClass.getResource("/swift-golden/$name.txt"), "falta $name").readText(Charsets.UTF_8)

    private fun assertGolden(name: String, actual: String) = assertEquals(golden(name), actual, "difiere de Swift: $name")

    private val root = "/home/u/mi repo's"

    @Test
    fun `comandos gh idénticos a Swift`() {
        assertGolden("gh-status", GitHubCommands.status(root))
        assertGolden("gh-create-pr", GitHubCommands.createPullRequest(root, draft = false))
        assertGolden("gh-create-pr-draft", GitHubCommands.createPullRequest(root, draft = true))
        assertGolden("gh-rerun", GitHubCommands.rerunFailed(root, 42853364727))
        assertGolden("gh-repos", GitHubCommands.repositories())
        assertGolden("gh-clone-home", GitHubCommands.clone(GitHubCloneRequest.make("victalejo/Argos", "~/proy ectos", "a'b")))
        assertGolden("gh-clone-abs", GitHubCommands.clone(GitHubCloneRequest.make("https://github.com/o/r.git", "/srv", "r")))
    }
}

class GitHubParserTest {

    private val sha = "7ac4b42277493bf9bc91d1f90806912228f602e1"

    private val prJson = """{"isDraft":false,"number":3,"reviewDecision":"CHANGES_REQUESTED","state":"OPEN",""" +
        """"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/1/job/2",""" +
        """"name":"build","status":"COMPLETED","workflowName":"Android"},{"__typename":"CheckRun","conclusion":"",""" +
        """"detailsUrl":"https://github.com/o/r/actions/runs/3/job/4","name":"test","status":"IN_PROGRESS","workflowName":"CI"},""" +
        """{"__typename":"StatusContext","context":"ci/externo","state":"FAILURE","targetUrl":"https://ci.example.com/9"}],""" +
        """"title":"fix(terminal): forzar UTF-8","url":"https://github.com/o/r/pull/3"}"""

    private val runsJson = """[{"conclusion":"","createdAt":"2026-11-10T16:19:27Z","databaseId":11,"displayTitle":"feat: x","event":"push",""" +
        """"headSha":"$sha","status":"in_progress","url":"https://github.com/o/r/actions/runs/11","workflowName":"CI"},""" +
        """{"conclusion":"failure","createdAt":"2026-11-10T16:00:00Z","databaseId":10,"displayTitle":"feat: x","event":"push",""" +
        """"headSha":"$sha","status":"completed","url":"https://github.com/o/r/actions/runs/10","workflowName":"CI"},""" +
        """{"conclusion":"success","createdAt":"2026-11-10T16:19:27Z","databaseId":12,"displayTitle":"feat: x","event":"push",""" +
        """"headSha":"$sha","status":"completed","url":"https://github.com/o/r/actions/runs/12","workflowName":"Android"}]"""

    private fun output(pr: String?, runs: String?) = buildString {
        append("motd del servidor\nARGOS_GH:sha $sha\nARGOS_GH:branch main\n")
        pr?.let { append("ARGOS_GH:pr $it \n") }
        runs?.let { append("ARGOS_GH:runs $it \n") }
    }

    @Test
    fun `PR con checks y CI por workflow con la última ejecución`() {
        val snapshot = assertIs<GitHubStatusResult.Loaded>(GitHubParser.parseStatus(output(prJson, runsJson))).snapshot
        assertEquals("7ac4b42", snapshot.shortSha)
        val pr = assertNotNull(snapshot.pullRequest)
        assertEquals(3, pr.number)
        assertEquals(GitHubPullRequest.Review.CHANGES_REQUESTED, pr.review)
        assertEquals("Piden cambios", pr.reviewLabel)
        assertEquals(listOf(GitHubCheckState.SUCCESS, GitHubCheckState.PENDING, GitHubCheckState.FAILURE), pr.checks.map { it.state })
        assertEquals("ci/externo", pr.checks[2].title)
        assertEquals(listOf("Android", "CI"), snapshot.runs.map { it.workflow })
        assertEquals(listOf(12L, 11L), snapshot.runs.map { it.id })
        assertEquals(GitHubCheckState.PENDING, snapshot.ciState)
        assertTrue(snapshot.isCIRunning)
        assertNull(snapshot.warning)
    }

    @Test
    fun `estados sin gh, sin sesión, sin GitHub y fallos`() {
        assertEquals(GitHubStatusResult.GhMissing, GitHubParser.parseStatus("ARGOS_GH:missing\n"))
        assertEquals(GitHubStatusResult.NotGitHub, GitHubParser.parseStatus("ARGOS_GH:sha \nARGOS_GH:branch \n"))
        assertEquals(GitHubStatusResult.NotAuthenticated, GitHubParser.parseStatus(output("please run:  gh auth login", null)))
        assertEquals(
            GitHubStatusResult.NotGitHub,
            GitHubParser.parseStatus(output("none of the git remotes configured for this repository point to a known GitHub host.", null)),
        )
        assertEquals(GitHubStatusResult.Failed("HTTP 502"), GitHubParser.parseStatus(output("HTTP 502", "HTTP 502")))
        val partial = assertIs<GitHubStatusResult.Loaded>(GitHubParser.parseStatus(output(prJson, "HTTP 502"))).snapshot
        assertEquals(3, partial.pullRequest?.number)
        assertEquals("HTTP 502", partial.warning)
        val noPr = assertIs<GitHubStatusResult.Loaded>(
            GitHubParser.parseStatus(output("no pull requests found for branch \"main\"", "[]")),
        ).snapshot
        assertNull(noPr.pullRequest)
        assertNull(noPr.ciState)
    }

    @Test
    fun `estados de Actions y agregados`() {
        assertEquals(GitHubCheckState.PENDING, GitHubCheckState.from("queued", null))
        assertEquals(GitHubCheckState.FAILURE, GitHubCheckState.from("completed", "timed_out"))
        assertEquals(GitHubCheckState.SUCCESS, GitHubCheckState.from("COMPLETED", "NEUTRAL"))
        assertEquals(GitHubCheckState.SUCCESS, GitHubCheckState.aggregate(listOf(GitHubCheckState.SKIPPED, GitHubCheckState.SUCCESS)))
        assertEquals(GitHubCheckState.SKIPPED, GitHubCheckState.aggregate(listOf(GitHubCheckState.SKIPPED)))
        assertEquals(
            GitHubCheckState.FAILURE,
            GitHubCheckState.aggregate(listOf(GitHubCheckState.SUCCESS, GitHubCheckState.PENDING, GitHubCheckState.FAILURE)),
        )
        assertNull(GitHubCheckState.aggregate(emptyList()))
    }

    @Test
    fun `repositorios, URL del PR y salida del clonado`() {
        val repos = GitHubParser.parseRepositories(
            """ARGOS_GH:repos [{"description":"","isPrivate":true,"nameWithOwner":"victalejo/roomies","updatedAt":"2026-11-09T03:04:53Z"}]""",
        )
        val list = assertIs<GitHubRepositoriesResult.Loaded>(repos).repositories
        assertEquals(listOf("roomies"), list.map { it.name })
        assertTrue(list.single().isPrivate)
        assertEquals(GitHubRepositoriesResult.GhMissing, GitHubParser.parseRepositories("ARGOS_GH:missing"))
        assertEquals("https://github.com/o/r/pull/8", GitHubParser.createdPullRequestUrl("Creating…\nhttps://github.com/o/r/pull/8\n"))
        assertEquals("/srv/app", GitHubParser.clonedPath("Cloning…\nARGOS_GH:path /srv/app\n"))
        assertNotNull(GitHubParser.cloneRefusal("ARGOS_GH:exists"))
        assertNull(GitHubParser.cloneRefusal("ARGOS_GH:path /x"))
    }
}

class GitHubCloneRequestTest {

    @Test
    fun `validación del repositorio`() {
        listOf("o/r", "victalejo/Argos.git", "https://github.com/o/r", "git@github.com:o/r.git").forEach {
            assertTrue(GitHubCloneRequest.isValidRepository(it), it)
        }
        listOf("-o/r", "o/-r", "o", "o/r/x", "o/r;rm", "../x", "https://a b").forEach {
            assertFalse(GitHubCloneRequest.isValidRepository(it), it)
        }
    }

    @Test
    fun `carpeta por defecto y carpetas no válidas`() {
        assertEquals("app", GitHubCloneRequest.defaultFolder("o/app.git"))
        assertEquals("app", GitHubCloneRequest.defaultFolder("https://github.com/o/app/"))
        assertEquals("app", GitHubCloneRequest.defaultFolder("git@github.com:o/app.git"))
        assertFailsWith<GitHubCloneRequest.InvalidException> { GitHubCloneRequest.make("o/r", "/srv", "a/b") }
        assertFailsWith<GitHubCloneRequest.InvalidException> { GitHubCloneRequest.make("o/r", " ", "r") }
        assertEquals(GitHubCloneRequest("o/app", "/srv", "app"), GitHubCloneRequest.make(" o/app ", "/srv", "app"))
    }
}

class CIWatcherTest {

    private val start: Instant = Instant.ofEpochSecond(1_800_000_000)

    private fun snapshot(sha: String = "abc", vararg runs: Pair<String, GitHubCheckState>) = GitHubStatusResult.Loaded(
        GitHubSnapshot(
            sha,
            "main",
            null,
            runs.mapIndexed { index, (workflow, state) -> GitHubRun(index.toLong(), workflow, "", state, null, "push", null) },
            null,
        ),
    )

    @Test
    fun `tras un push fija el commit, espera a todos y avisa una vez`() {
        var watcher = CIWatcher().watch("/r", "app", null, start)
        assertTrue(watcher.isDue(start))
        val (next, done) = watcher.apply(snapshot(runs = arrayOf("CI" to GitHubCheckState.PENDING)), "/r", start)
        assertNull(done)
        assertEquals("abc", next.watches["/r"]?.sha)
        watcher = next
        // Un workflow falló pero otro sigue: aún no se avisa.
        val waiting = watcher.apply(snapshot(runs = arrayOf("CI" to GitHubCheckState.FAILURE, "Android" to GitHubCheckState.PENDING)), "/r", start)
        assertNull(waiting.second)
        val (finalWatcher, result) = waiting.first.apply(
            snapshot(runs = arrayOf("CI" to GitHubCheckState.FAILURE, "Android" to GitHubCheckState.SUCCESS)),
            "/r",
            start.plusSeconds(60),
        )
        assertEquals(GitHubCheckState.FAILURE, result?.state)
        assertEquals(listOf("CI"), result?.failed)
        assertEquals("CI de «app»: falló", result?.title)
        assertTrue(finalWatcher.isEmpty)
    }

    @Test
    fun `sin ejecuciones se deja, la red se reintenta y otro commit lo descarta`() {
        val watcher = CIWatcher().watch("/r", "app", "abc", start)
        assertFalse(watcher.apply(GitHubStatusResult.Failed("red"), "/r", start).first.isEmpty)
        assertFalse(watcher.apply(snapshot(), "/r", start.plusSeconds(10)).first.isEmpty)
        assertTrue(watcher.apply(snapshot(), "/r", start + CIWatcher.NO_RUNS_GIVE_UP + Duration.ofSeconds(1)).first.isEmpty)
        assertTrue(watcher.apply(snapshot("def", "CI" to GitHubCheckState.PENDING), "/r", start).first.isEmpty)
        assertTrue(watcher.apply(GitHubStatusResult.NotGitHub, "/r", start).first.isEmpty)
    }

    @Test
    fun `repetir no reinicia la espera y el panel completa el commit`() {
        val watcher = CIWatcher().watch("/r", "app", null, start).watch("/r", "otro", "abc", start.plusSeconds(50))
        assertEquals("abc", watcher.watches["/r"]?.sha)
        assertEquals(start, watcher.watches["/r"]?.since)
        assertEquals(start, watcher.watch("/r", "app", "abc", start.plusSeconds(90)).watches["/r"]?.since)
        val polled = watcher.polled(start)
        assertFalse(polled.isDue(start.plusSeconds(5)))
        assertTrue(polled.isDue(start + CIWatcher.POLL_INTERVAL))
    }
}
