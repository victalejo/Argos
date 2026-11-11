package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.SSHServicing
import com.iaportafolio.argos.core.agent.AgentExecStreaming
import com.iaportafolio.argos.core.agent.ClaudeAuthStatus
import com.iaportafolio.argos.core.git.GitBranchInfo
import com.iaportafolio.argos.core.git.GitCommands
import com.iaportafolio.argos.core.git.GitFileChange
import com.iaportafolio.argos.core.git.GitFileDiff
import com.iaportafolio.argos.core.git.GitOperations
import com.iaportafolio.argos.core.git.GitRepoSummary
import com.iaportafolio.argos.core.git.GitRepositoryStatus
import com.iaportafolio.argos.core.git.GitStatusResult
import com.iaportafolio.argos.core.git.GitWorktreeListResult
import com.iaportafolio.argos.core.git.GitWorktreeRequest
import com.iaportafolio.argos.core.github.GitHubCloneRequest
import com.iaportafolio.argos.core.github.GitHubOperations
import com.iaportafolio.argos.core.github.GitHubRepositoriesResult
import com.iaportafolio.argos.core.github.GitHubStatusResult
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first

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
class FakeGitService(base: FakeSSHService = FakeSSHService()) :
    SSHServicing by base, GitOperations, GitHubOperations, AgentExecStreaming {
    // «Sugerir mensaje»: `claude` del servidor y lo que responde (líneas de la salida).
    var claudePath: String? = "/usr/bin/claude"
    var agentLines: List<String> = emptyList()
    var agentCommand: String? = null
    var agentStdinFirstLine: String? = null

    override suspend fun locateClaude(): String? = claudePath

    override suspend fun runAgentExec(command: String, stdin: Flow<ByteArray>, output: suspend (ByteArray) -> Unit) {
        agentCommand = command
        agentStdinFirstLine = stdin.first().decodeToString().trimEnd('\n')
        agentLines.forEach { output((it + "\n").encodeToByteArray()) }
    }

    override suspend fun claudeAuthStatus(): ClaudeAuthStatus? = null

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

    // MARK: Worktrees
    var worktreeListing: GitWorktreeListResult = GitWorktreeListResult.NotRepository
    val addedWorktrees = mutableListOf<GitWorktreeRequest>()
    val removedWorktrees = mutableListOf<Pair<String, Boolean>>()
    var addedWorktreePath: String? = null

    override suspend fun gitWorktrees(path: String): GitWorktreeListResult = worktreeListing

    override suspend fun gitAddWorktree(request: GitWorktreeRequest): String {
        error?.let { throw it }
        addedWorktrees += request
        return addedWorktreePath ?: request.path
    }

    override suspend fun gitRemoveWorktree(repository: String, path: String, force: Boolean) {
        error?.let { throw it }
        removedWorktrees += path to force
    }

    // MARK: GitHub
    var gitHubStatus: GitHubStatusResult = GitHubStatusResult.NotGitHub
    var gitHubError: Exception? = null
    val gitHubStatusRequests = mutableListOf<String>()
    val createdPullRequests = mutableListOf<Boolean>()
    val reruns = mutableListOf<Long>()
    var repositories: GitHubRepositoriesResult = GitHubRepositoriesResult.Loaded(emptyList())
    val cloneRequests = mutableListOf<GitHubCloneRequest>()
    var clonedPath = "/srv/clonado"

    override suspend fun gitHubStatus(root: String): GitHubStatusResult {
        gitHubStatusRequests += root
        gitHubError?.let { throw it }
        return gitHubStatus
    }

    override suspend fun gitHubCreatePullRequest(root: String, draft: Boolean): String? {
        gitHubError?.let { throw it }
        createdPullRequests += draft
        return "https://github.com/o/r/pull/7"
    }

    override suspend fun gitHubRerunFailed(root: String, runId: Long) {
        gitHubError?.let { throw it }
        reruns += runId
    }

    override suspend fun gitHubRepositories(): GitHubRepositoriesResult {
        gitHubError?.let { throw it }
        return repositories
    }

    override suspend fun gitHubClone(request: GitHubCloneRequest): String {
        gitHubError?.let { throw it }
        cloneRequests += request
        return clonedPath
    }
}
