package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.git.GitChangeKind
import com.iaportafolio.argos.core.git.GitCommandException
import com.iaportafolio.argos.core.git.GitRepositoryStatus
import com.iaportafolio.argos.core.git.GitStatusResult
import com.iaportafolio.argos.ssh.testing.EmbeddedSshServer
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createDirectories
import kotlin.io.path.exists
import kotlin.io.path.readText
import kotlin.io.path.writeText
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Panel «Cambios» de punta a punta: sshj → MINA SSHD (`/bin/sh -c`) → git real sobre un repo
 * temporal. Cubre estado, diff, commit selectivo, descarte con rutas literales y el resumen.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjGitIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService
    private lateinit var repo: Path
    private lateinit var plain: Path

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(dir.resolve("server")), password = PASSWORD)
        service = SshjConnector().service(
            testServer(server.port),
            SSHCredentials.Password(PASSWORD),
            InMemoryTrustStore(),
        ) as SshjSSHService
        repo = server.home.resolve("proyectos/app").createDirectories()
        plain = server.home.resolve("proyectos/sin-git").createDirectories()
        git("init", "-q", "-b", "main")
        git("config", "user.email", "t@t")
        git("config", "user.name", "t")
        repo.resolve("tracked.txt").writeText("uno\ndos\n")
        repo.resolve("otro.txt").writeText("base\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        server.close()
    }

    private fun git(vararg args: String) = runProcess("git", "-C", repo.toString(), *args)

    private suspend fun status(): GitRepositoryStatus =
        assertIs<GitStatusResult.Repository>(service.gitStatus(repo.toString())).status

    @Test
    fun `estado, diff, commit selectivo, descarte literal y resumen`() = runBlocking {
        assertEquals(GitStatusResult.NotRepository, service.gitStatus(plain.toString()))

        repo.resolve("tracked.txt").writeText("uno\nDOS\n")
        repo.resolve("otro.txt").writeText("cambiado\n")
        repo.resolve("*").writeText("comodín\n")
        repo.resolve("importante.txt").writeText("no borrar\n")

        val before = status()
        assertEquals("main", before.branch.name)
        assertEquals(setOf("tracked.txt", "otro.txt", "*", "importante.txt"), before.changes.map { it.path }.toSet())
        val tracked = before.changes.first { it.path == "tracked.txt" }
        assertEquals(GitChangeKind.MODIFIED, tracked.kind)

        val diff = service.gitDiff(before.root, tracked, hasCommits = true)
        assertEquals(1, diff.additions)
        assertEquals(1, diff.deletions)

        val summaries = service.gitSummaries(listOf(repo.toString(), plain.toString()))
        assertEquals(4, summaries[repo.toString()]?.changedCount)
        assertFalse(plain.toString() in summaries)

        // Descartar el archivo «*» solo borra ese: las rutas son literales.
        service.gitDiscard(before.root, before.changes.first { it.path == "*" })
        assertFalse(repo.resolve("*").exists())
        assertTrue(repo.resolve("importante.txt").exists())

        // Commit solo de tracked.txt: otro.txt sigue modificado.
        val output = service.gitCommit(before.root, "fix: solo uno", listOf(tracked))
        assertTrue("fix: solo uno" in output)
        assertEquals(setOf("otro.txt", "importante.txt"), status().changes.map { it.path }.toSet())

        service.gitDiscard(before.root, status().changes.first { it.path == "otro.txt" })
        assertEquals("base\n", repo.resolve("otro.txt").readText())

        // Sin remoto, push falla con el mensaje de git (no se cuelga pidiendo contraseña).
        assertFailsWith<GitCommandException> { service.gitPush(before.root, hasUpstream = false) }
        Unit
    }

    private companion object {
        const val PASSWORD = "argos-test"
    }
}
