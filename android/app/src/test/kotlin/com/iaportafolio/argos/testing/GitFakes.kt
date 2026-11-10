package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.git.GitBranchInfo
import com.iaportafolio.argos.core.git.GitCommands
import com.iaportafolio.argos.core.git.GitFileChange
import com.iaportafolio.argos.core.git.GitFileDiff
import com.iaportafolio.argos.core.git.GitOperations
import com.iaportafolio.argos.core.git.GitRepoSummary
import com.iaportafolio.argos.core.git.GitRepositoryStatus
import com.iaportafolio.argos.core.git.GitStatusResult

/** Estado git de prueba con raíz `/r` y rama `main` (como el de `GitTests.swift`). */
fun gitStatus(changes: List<GitFileChange>, upstream: String? = "origin/main", ahead: Int = 0): GitStatusResult =
    GitStatusResult.Repository(
        GitRepositoryStatus(
            root = "/r",
            branch = GitBranchInfo("main", upstream, ahead, 0, hasCommits = true, upstreamGone = false),
            changes = changes,
            truncated = false,
        ),
    )

/** [SSHServicing] de tmux/proyectos ([FakeSSHService]) + git en memoria (port del `MockSSHService`). */
class FakeGitService(base: FakeSSHService = FakeSSHService()) : SSHServicing by base, GitOperations {
    var statusResult: GitStatusResult = GitStatusResult.NotRepository
    var diffResult: GitFileDiff = GitFileDiff.EMPTY
    var summaries: Map<String, GitRepoSummary> = emptyMap()
    var error: Exception? = null
    var commitOutput = "[main abc1234] fix: algo\n 1 file changed"

    val diffRequests = mutableListOf<String>()
    val discarded = mutableListOf<GitFileChange>()
    val commits = mutableListOf<Pair<String, List<String>>>()
    val pushes = mutableListOf<Boolean>()
    val summaryRequests = mutableListOf<List<String>>()

    override suspend fun gitStatus(path: String): GitStatusResult = statusResult

    override suspend fun gitDiff(root: String, change: GitFileChange, hasCommits: Boolean): GitFileDiff {
        diffRequests += change.path
        return diffResult
    }

    override suspend fun gitDiscard(root: String, change: GitFileChange) {
        error?.let { throw it }
        discarded += change
    }

    override suspend fun gitCommit(root: String, message: String, changes: List<GitFileChange>): String {
        error?.let { throw it }
        commits += message to GitCommands.commitPaths(changes)
        return commitOutput
    }

    override suspend fun gitPush(root: String, hasUpstream: Boolean): String {
        error?.let { throw it }
        pushes += hasUpstream
        return ""
    }

    override suspend fun gitPull(root: String): String {
        error?.let { throw it }
        return "Already up to date."
    }

    override suspend fun gitSummaries(paths: List<String>): Map<String, GitRepoSummary> {
        summaryRequests += paths
        error?.let { throw it }
        return summaries
    }
}
