package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.SSHCredentials
import com.iaportafolio.argos.core.git.GitCommandException
import com.iaportafolio.argos.core.github.GitHubCloneRequest
import com.iaportafolio.argos.core.github.GitHubStatusResult
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
import kotlin.io.path.listDirectoryEntries
import kotlin.test.assertContains
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * GitHub de punta a punta por sshj → MINA SSHD (`/bin/sh -c`). No depende de que `gh` esté
 * instalado ni con sesión (en la CI no lo está): cubre lo que el script decide antes de llamar a
 * GitHub (repo sin remoto de GitHub, carpeta existente o padre inexistente al clonar).
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class SshjGitHubIntegrationTest {

    private lateinit var server: EmbeddedSshServer
    private lateinit var service: SshjSSHService
    private lateinit var repo: Path

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
        runProcess("git", "-C", repo.toString(), "init", "-q")
    }

    @AfterAll
    fun stop() {
        runBlocking { service.disconnect() }
        server.close()
    }

    @Test
    fun `sin remoto de GitHub, sin gh o sin sesión se distingue (nunca se cuelga)`() = runBlocking {
        // HOME aislado: con gh instalado, gh dice antes «sin sesión» que «sin remoto».
        val result = service.gitHubStatus(repo.toString())
        val expected = setOf(GitHubStatusResult.NotGitHub, GitHubStatusResult.GhMissing, GitHubStatusResult.NotAuthenticated)
        assertTrue(result in expected, "$result")
    }

    @Test
    fun `clonar nunca pisa una carpeta existente ni crea el padre`() = runBlocking {
        val parent = repo.parent.toString()
        val exists = assertFailsWith<GitCommandException> { service.gitHubClone(GitHubCloneRequest.make("o/r", parent, "app")) }
        assertContains(exists.message.orEmpty(), "Ya existe")
        val noParent = assertFailsWith<GitCommandException> {
            service.gitHubClone(GitHubCloneRequest.make("o/r", "$parent/no-existe", "r"))
        }
        assertContains(noParent.message.orEmpty(), "no existe")
        assertTrue(repo.listDirectoryEntries().map { it.fileName.toString() } == listOf(".git"))
    }

    private companion object {
        const val PASSWORD = "argos-test"
    }
}
