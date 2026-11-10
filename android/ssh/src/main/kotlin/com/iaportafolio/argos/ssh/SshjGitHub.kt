package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.git.GitCommandException
import com.iaportafolio.argos.core.github.GitHubCloneRequest
import com.iaportafolio.argos.core.github.GitHubCommands
import com.iaportafolio.argos.core.github.GitHubOperations
import com.iaportafolio.argos.core.github.GitHubParser
import com.iaportafolio.argos.core.github.GitHubRepositoriesResult
import com.iaportafolio.argos.core.github.GitHubStatusResult

/**
 * GitHub por el `gh` del servidor (port de `ArgosCore/GitHub/SSHGitHub.swift`), con comandos cortos
 * del canal de comandos. Los comandos los arma [GitHubCommands] (byte a byte los de Apple).
 */
internal class SshjGitHub(private val connection: SshjConnection) : GitHubOperations {

    override suspend fun gitHubStatus(root: String): GitHubStatusResult =
        GitHubParser.parseStatus(connection.capture(GitHubCommands.status(root)).stdout)

    override suspend fun gitHubCreatePullRequest(root: String, draft: Boolean): String? =
        GitHubParser.createdPullRequestUrl(run(GitHubCommands.createPullRequest(root, draft)))

    override suspend fun gitHubRerunFailed(root: String, runId: Long) {
        run(GitHubCommands.rerunFailed(root, runId))
    }

    override suspend fun gitHubRepositories(): GitHubRepositoriesResult =
        GitHubParser.parseRepositories(connection.capture(GitHubCommands.repositories()).stdout)

    override suspend fun gitHubClone(request: GitHubCloneRequest): String {
        val result = connection.capture(GitHubCommands.clone(request))
        GitHubParser.cloneRefusal(result.stdout)?.let { throw GitCommandException(it) }
        if (result.exitCode != 0) throw GitCommandException.from(result.stdout, result.stderr, result.exitCode)
        return GitHubParser.clonedPath(result.stdout)
            ?: throw GitCommandException("El clonado terminó pero no se encontró la carpeta.")
    }

    /** Ejecuta un comando `gh` (con `2>&1`) y devuelve su salida; lanza si falla. */
    private suspend fun run(command: String): String {
        val result = connection.capture(command)
        if (result.exitCode != 0) throw GitCommandException.from(result.stdout, result.stderr, result.exitCode)
        return result.stdout
    }
}
