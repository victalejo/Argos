package com.iaportafolio.argos.core.github

/**
 * GitHub con el `gh` del servidor (port de la parte GitHub de `SSHServicing`). Separado igual que
 * `GitOperations`: Argos nunca custodia tokens de GitHub.
 */
interface GitHubOperations {
    /** PR de la rama actual y ejecuciones de Actions de HEAD. */
    suspend fun gitHubStatus(root: String): GitHubStatusResult

    /** Abre un PR de la rama actual (`--fill`); devuelve su URL. */
    suspend fun gitHubCreatePullRequest(root: String, draft: Boolean): String?

    /** Relanza los jobs fallidos de una ejecución de Actions. */
    suspend fun gitHubRerunFailed(root: String, runId: Long)

    /** Repositorios del usuario de `gh` (para clonar uno como proyecto). */
    suspend fun gitHubRepositories(): GitHubRepositoriesResult

    /** Clona y devuelve la ruta absoluta de la carpeta creada. */
    suspend fun gitHubClone(request: GitHubCloneRequest): String
}
