package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.git.GitCommandException
import com.iaportafolio.argos.core.git.GitWorktreeListResult
import com.iaportafolio.argos.core.git.GitWorktreeRequest
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
import kotlin.io.path.writeText
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * «Ramas en paralelo» de punta a punta: sshj → MINA SSHD (`/bin/sh -c`) → git real. Crear, negarse a
 * pisar una carpeta, contar cambios, negarse a quitar con cambios sin forzar y reabrir la rama.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjWorktreeIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService
    private lateinit var repo: Path

    @BeforeAll
    fun start(@TempDir dir: Path) {
        SshjConnector.installSecurityProvider()
        server = EmbeddedSshServer.start(Files.createDirectories(dir.resolve("server")), password = PASSWORD)
        service = SshjConnector().service(testServer(server.port), SSHCredentials.Password(PASSWORD), InMemoryTrustStore()) as SshjSSHService
        repo = server.home.resolve("proyectos/app").createDirectories().toRealPath()
        runProcess("git", "-C", repo.toString(), "init", "-q", "-b", "main")
        runProcess("git", "-C", repo.toString(), "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        server.close()
    }

    private suspend fun listing() = assertIs<GitWorktreeListResult.Loaded>(service.gitWorktrees(repo.toString())).listing

    @Test
    fun `crear, contar cambios, quitar con y sin forzar y reabrir la rama`(): Unit = runBlocking {
        val first = listing()
        assertEquals(listOf("main"), first.worktrees.map { it.branch })
        val path = requireNotNull(first.defaultPath("feat/login"))
        val request = GitWorktreeRequest.make(first, "feat/login", true, "main", path)
        val created = service.gitAddWorktree(request)
        assertTrue(Path.of(created).exists())

        val again = assertFailsWith<GitCommandException> { service.gitAddWorktree(request) }
        assertTrue("Ya existe" in again.message.orEmpty())
        val bad = assertFailsWith<GitCommandException> {
            service.gitAddWorktree(GitWorktreeRequest(repo.toString(), "mal..rama", true, "main", "$path-2"))
        }
        assertTrue("no es válido" in bad.message.orEmpty())

        Path.of(created, "nuevo.txt").writeText("x")
        val dirty = listing().worktrees.first { it.branch == "feat/login" }
        assertEquals(1, dirty.changedCount)
        assertFailsWith<GitCommandException> { service.gitRemoveWorktree(repo.toString(), dirty.path, force = false) }
        service.gitRemoveWorktree(repo.toString(), dirty.path, force = true)
        assertFalse(Path.of(created).exists())

        val after = listing()
        assertEquals(listOf("feat/login"), after.freeBranches)
        val reopened = service.gitAddWorktree(GitWorktreeRequest.make(after, "feat/login", false, "", path))
        assertTrue(Path.of(reopened).exists())
    }

    private companion object {
        const val PASSWORD = "argos-test"
    }
}
