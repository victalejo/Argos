package com.iaportafolio.argos.ssh

import com.iaportafolio.argos.core.git.GitCommandException
import com.iaportafolio.argos.core.git.GitCommands
import com.iaportafolio.argos.core.git.GitDiffParser
import com.iaportafolio.argos.core.git.GitFileChange
import com.iaportafolio.argos.core.git.GitFileDiff
import com.iaportafolio.argos.core.git.GitOperations
import com.iaportafolio.argos.core.git.GitRepoSummary
import com.iaportafolio.argos.core.git.GitStatusParser
import com.iaportafolio.argos.core.git.GitStatusResult
import com.iaportafolio.argos.core.git.GitSummaryCommands
import com.iaportafolio.argos.core.git.GitSummaryParser

/**
 * Operaciones git del panel «Cambios» (port de `ArgosCore/Git/SSHGit.swift`) por el canal de
 * comandos de la conexión compartida. Los comandos los arma [GitCommands] (byte a byte los de Apple).
 */
internal class SshjGit(private val connection: SshjConnection) : GitOperations {

    override suspend fun gitStatus(path: String): GitStatusResult =
        GitStatusParser.parse(connection.capture(GitCommands.status(path)).stdout)

    override suspend fun gitDiff(root: String, change: GitFileChange, hasCommits: Boolean): GitFileDiff {
        val result = connection.capture(GitCommands.diff(root, change, hasCommits))
        // `head` es el último del pipe: el código es el suyo. Error solo si no hubo salida.
        if (result.stdout.isEmpty() && result.stderr.isNotEmpty()) {
            throw GitCommandException.from("", result.stderr, result.exitCode)
        }
        val truncated = result.stdout.toByteArray(Charsets.UTF_8).size > GitCommands.DIFF_BYTE_LIMIT
        return GitDiffParser.parse(result.stdout, truncated)
    }

    override suspend fun gitDiscard(root: String, change: GitFileChange) {
        runGit(GitCommands.discard(root, change))
    }

    override suspend fun gitCommit(root: String, message: String, changes: List<GitFileChange>): String =
        runGit(GitCommands.commit(root, message, changes))

    override suspend fun gitPush(root: String, hasUpstream: Boolean): String = runGit(GitCommands.push(root, hasUpstream))

    override suspend fun gitPull(root: String): String = runGit(GitCommands.pull(root))

    override suspend fun gitSummaries(paths: List<String>): Map<String, GitRepoSummary> {
        if (paths.isEmpty()) return emptyMap()
        return GitSummaryParser.parse(connection.capture(GitSummaryCommands.summaries(paths)).stdout, paths)
    }

    /** Ejecuta un comando git y devuelve su salida (recortada); lanza si falla. */
    private suspend fun runGit(command: String): String {
        val result = connection.capture(command)
        if (result.exitCode != 0) throw GitCommandException.from(result.stdout, result.stderr, result.exitCode)
        return result.stdout.trim()
    }
}
