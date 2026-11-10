package com.iaportafolio.argos.core.git

/**
 * Operaciones git del panel «Cambios» (port de `ArgosCore/Git/SSHGit.swift`). Separado de
 * `SSHServicing` igual que `RemoteFileBrowsing`: git corre EN EL SERVIDOR por el canal de
 * comandos; Argos nunca clona ni guarda credenciales.
 */
interface GitOperations {
    suspend fun gitStatus(path: String): GitStatusResult
    suspend fun gitDiff(root: String, change: GitFileChange, hasCommits: Boolean): GitFileDiff
    suspend fun gitDiscard(root: String, change: GitFileChange)

    /** Devuelve la salida de `git commit` (su primera línea resume el commit). */
    suspend fun gitCommit(root: String, message: String, changes: List<GitFileChange>): String
    suspend fun gitPush(root: String, hasUpstream: Boolean): String
    suspend fun gitPull(root: String): String

    /** Resumen de varias carpetas en un solo comando (las que no son repo no aparecen). */
    suspend fun gitSummaries(paths: List<String>): Map<String, GitRepoSummary>

    /** Worktrees del repositorio de [path] y sus ramas locales («Ramas en paralelo»). */
    suspend fun gitWorktrees(path: String): GitWorktreeListResult

    /** Crea el worktree (y la rama, si es nueva); devuelve su ruta real. */
    suspend fun gitAddWorktree(request: GitWorktreeRequest): String

    /** Quita el worktree ([force]: aunque tenga cambios sin confirmar). La rama se conserva. */
    suspend fun gitRemoveWorktree(repository: String, path: String, force: Boolean)
}

/** Fallo de una operación git, con el mensaje de git para mostrarlo tal cual. */
class GitCommandException(message: String) : Exception(message) {
    companion object {
        /**
         * Mensaje útil a partir de la salida: git suele explicar el problema en las últimas líneas
         * (p. ej. «Please tell me who you are», «rejected»).
         */
        fun from(stdout: String, stderr: String, exitCode: Int): GitCommandException {
            val text = listOf(stderr, stdout).map { it.trim() }.firstOrNull { it.isNotEmpty() }
                ?: return GitCommandException("git terminó con código $exitCode.")
            return GitCommandException(text.lines().filter { it.isNotEmpty() }.takeLast(8).joinToString("\n"))
        }
    }
}
