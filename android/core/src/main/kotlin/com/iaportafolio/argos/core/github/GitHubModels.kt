package com.iaportafolio.argos.core.github

import java.time.Instant

/**
 * Estado de GitHub de un repositorio del servidor (port de `ArgosCore/GitHub/GitHubModels.swift`):
 * el PR de la rama actual con sus checks y las ejecuciones de Actions del commit HEAD. Todo sale
 * del `gh` del SERVIDOR (Argos nunca guarda tokens de GitHub); lo parsea [GitHubParser].
 */
enum class GitHubCheckState(private val severity: Int, val label: String) {
    PENDING(3, "En curso"),
    SUCCESS(1, "Pasó"),
    FAILURE(4, "Falló"),
    CANCELLED(2, "Cancelado"),
    SKIPPED(0, "Omitido"),
    ;

    companion object {
        /** Estado de un conjunto (`null` si está vacío): el más grave, ignorando omitidos si hay más. */
        fun aggregate(states: List<GitHubCheckState>): GitHubCheckState? {
            val relevant = states.filter { it != SKIPPED }.ifEmpty { states }
            return relevant.maxByOrNull { it.severity }
        }

        /** `status`/`conclusion` de Actions (minúsculas) o de un CheckRun (mayúsculas). */
        fun from(status: String?, conclusion: String?): GitHubCheckState {
            if (status?.lowercase() != "completed") return PENDING
            return when (conclusion?.lowercase()) {
                "success", "neutral" -> SUCCESS
                "skipped" -> SKIPPED
                "cancelled", "stale" -> CANCELLED
                else -> FAILURE
            }
        }

        /** `state` de un StatusContext (estados de commit clásicos). */
        fun fromContextState(state: String?): GitHubCheckState = when (state?.uppercase()) {
            "SUCCESS" -> SUCCESS
            "PENDING", "EXPECTED" -> PENDING
            else -> FAILURE
        }
    }
}

/** Un check del PR (CheckRun de Actions o estado de commit de otro servicio). */
data class GitHubCheck(val name: String, val workflow: String, val state: GitHubCheckState, val url: String?) {
    val title: String get() = if (workflow.isEmpty()) name else "$workflow · $name"
}

/** Pull request de la rama actual. */
data class GitHubPullRequest(
    val number: Int,
    val title: String,
    val url: String?,
    val state: State,
    val isDraft: Boolean,
    val review: Review?,
    val checks: List<GitHubCheck>,
) {
    enum class State { OPEN, CLOSED, MERGED }

    enum class Review { APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED }

    val checksState: GitHubCheckState? get() = GitHubCheckState.aggregate(checks.map { it.state })

    val stateLabel: String
        get() = when (state) {
            State.MERGED -> "Fusionado"
            State.CLOSED -> "Cerrado"
            State.OPEN -> if (isDraft) "Borrador" else "Abierto"
        }

    val reviewLabel: String?
        get() = when (review) {
            Review.APPROVED -> "Aprobado"
            Review.CHANGES_REQUESTED -> "Piden cambios"
            Review.REVIEW_REQUIRED -> "Revisión pendiente"
            null -> null
        }
}

/** Una ejecución de GitHub Actions del commit HEAD. */
data class GitHubRun(
    val id: Long,
    val workflow: String,
    val title: String,
    val state: GitHubCheckState,
    val url: String?,
    val event: String,
    val createdAt: Instant?,
)

/** Todo lo que el panel muestra de GitHub para un repositorio. */
data class GitHubSnapshot(
    val headSha: String,
    val branch: String?,
    val pullRequest: GitHubPullRequest?,
    /** Última ejecución de cada workflow para HEAD. */
    val runs: List<GitHubRun>,
    /** Fallo al leer una de las partes (la otra sí se pudo leer). */
    val warning: String?,
) {
    val ciState: GitHubCheckState? get() = GitHubCheckState.aggregate(runs.map { it.state })
    val failedRuns: List<GitHubRun> get() = runs.filter { it.state == GitHubCheckState.FAILURE }

    /** Queda algún workflow en marcha (aunque otro ya haya fallado): el CI no ha terminado. */
    val isCIRunning: Boolean get() = runs.any { it.state == GitHubCheckState.PENDING }
    val shortSha: String get() = headSha.take(7)
}

/** Resultado de consultar GitHub desde el servidor. */
sealed interface GitHubStatusResult {
    /** `gh` no está instalado en el servidor. */
    data object GhMissing : GitHubStatusResult

    /** `gh` no tiene sesión iniciada (`gh auth login` en el servidor). */
    data object NotAuthenticated : GitHubStatusResult

    /** El repositorio no tiene un remoto de GitHub. */
    data object NotGitHub : GitHubStatusResult
    data class Loaded(val snapshot: GitHubSnapshot) : GitHubStatusResult
    data class Failed(val message: String) : GitHubStatusResult
}

/** Repositorio del usuario (para clonarlo como proyecto nuevo). */
data class GitHubRepository(
    val nameWithOwner: String,
    val description: String,
    val isPrivate: Boolean,
    val updatedAt: Instant?,
) {
    /** Nombre de carpeta por defecto al clonar. */
    val name: String get() = nameWithOwner.substringAfterLast('/')
}

/** Lista de repositorios del usuario de `gh`. */
sealed interface GitHubRepositoriesResult {
    data object GhMissing : GitHubRepositoriesResult
    data object NotAuthenticated : GitHubRepositoriesResult
    data class Loaded(val repositories: List<GitHubRepository>) : GitHubRepositoriesResult
    data class Failed(val message: String) : GitHubRepositoriesResult
}
