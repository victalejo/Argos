package com.iaportafolio.argos.core.github

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.format.DateTimeParseException

/**
 * Parser puro de la salida de [GitHubCommands] (port de `GitHubParser.swift`): líneas
 * `ARGOS_GH:<clave> <valor>`, donde el valor de `pr`/`runs`/`repos` es el JSON de `gh` o su error.
 */
object GitHubParser {

    /** Valor de cada clave (la última aparición gana; el ruido del perfil se ignora). */
    fun fields(output: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        for (line in output.lines()) {
            val at = line.indexOf(GitHubCommands.MARKER)
            if (at < 0) continue
            val rest = line.substring(at + GitHubCommands.MARKER.length)
            val key = rest.substringBefore(' ')
            result[key] = rest.substring(key.length).trim(' ', '\t', '\r')
        }
        return result
    }

    // MARK: - Estado

    fun parseStatus(output: String): GitHubStatusResult {
        val fields = fields(output)
        if ("missing" in fields) return GitHubStatusResult.GhMissing
        val sha = fields["sha"]?.takeIf { it.isNotEmpty() } ?: return GitHubStatusResult.NotGitHub
        val branch = fields["branch"]?.takeIf { it.isNotEmpty() }

        var pullRequest: GitHubPullRequest? = null
        val warnings = mutableListOf<String>()
        fields["pr"]?.let { raw ->
            when (val classified = classify(raw)) {
                is Classified.Json -> pullRequest = decodePullRequest(classified.element)
                Classified.NoPullRequest -> Unit
                Classified.NotAuthenticated -> return GitHubStatusResult.NotAuthenticated
                Classified.NotGitHub -> return GitHubStatusResult.NotGitHub
                is Classified.Error -> warnings += classified.message
            }
        }
        var runs = emptyList<GitHubRun>()
        fields["runs"]?.let { raw ->
            when (val classified = classify(raw)) {
                is Classified.Json -> runs = latestPerWorkflow(decodeRuns(classified.element))
                Classified.NoPullRequest -> Unit
                Classified.NotAuthenticated -> return GitHubStatusResult.NotAuthenticated
                Classified.NotGitHub -> return GitHubStatusResult.NotGitHub
                is Classified.Error -> warnings += classified.message
            }
        }
        // Si TODAS las consultas fallaron no hay nada que enseñar: es un error.
        val asked = listOfNotNull(fields["pr"], fields["runs"]).size
        if (asked > 0 && warnings.size == asked) return GitHubStatusResult.Failed(warnings.first())
        return GitHubStatusResult.Loaded(GitHubSnapshot(sha, branch, pullRequest, runs, warnings.firstOrNull()))
    }

    sealed interface Classified {
        data class Json(val element: JsonElement) : Classified
        data object NoPullRequest : Classified
        data object NotAuthenticated : Classified
        data object NotGitHub : Classified
        data class Error(val message: String) : Classified
    }

    /** Distingue el JSON de los errores conocidos de `gh` (que van por stderr → misma línea). */
    fun classify(raw: String): Classified {
        val text = raw.trim()
        if (text.startsWith("{") || text.startsWith("[")) {
            runCatching { JSON.parseToJsonElement(text) }.getOrNull()?.let { return Classified.Json(it) }
        }
        val lower = text.lowercase()
        return when {
            "no pull requests found" in lower -> Classified.NoPullRequest
            "gh auth login" in lower || "not logged in" in lower || "authentication" in lower -> Classified.NotAuthenticated
            listOf("none of the git remotes", "not a git repository", "could not determine base repo", "no git remotes")
                .any { it in lower } -> Classified.NotGitHub
            text.isEmpty() -> Classified.Error("gh no devolvió nada.")
            else -> Classified.Error(text.take(400))
        }
    }

    // MARK: - JSON

    private val JSON = Json { ignoreUnknownKeys = true }

    private fun JsonObject.string(key: String): String? = (this[key] as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull

    fun decodePullRequest(element: JsonElement): GitHubPullRequest? {
        val obj = element as? JsonObject ?: return null
        val number = obj["number"]?.jsonPrimitive?.intOrNull ?: return null
        val checks = (obj["statusCheckRollup"] as? JsonArray).orEmpty().mapNotNull { item ->
            val check = item as? JsonObject ?: return@mapNotNull null
            if (check.string("__typename") == "StatusContext") {
                GitHubCheck(check.string("context") ?: "estado", "", GitHubCheckState.fromContextState(check.string("state")), url(check.string("targetUrl")))
            } else {
                GitHubCheck(
                    check.string("name") ?: "check",
                    check.string("workflowName").orEmpty(),
                    GitHubCheckState.from(check.string("status"), check.string("conclusion")),
                    url(check.string("detailsUrl")),
                )
            }
        }
        return GitHubPullRequest(
            number = number,
            title = obj.string("title").orEmpty(),
            url = url(obj.string("url")),
            state = runCatching { GitHubPullRequest.State.valueOf(obj.string("state").orEmpty().uppercase()) }
                .getOrDefault(GitHubPullRequest.State.OPEN),
            isDraft = obj["isDraft"]?.jsonPrimitive?.booleanOrNull ?: false,
            review = obj.string("reviewDecision")?.let { value -> GitHubPullRequest.Review.entries.firstOrNull { it.name == value } },
            checks = checks,
        )
    }

    fun decodeRuns(element: JsonElement): List<GitHubRun> = (element as? JsonArray).orEmpty().mapNotNull { item ->
        val run = item as? JsonObject ?: return@mapNotNull null
        val id = run["databaseId"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null
        GitHubRun(
            id = id,
            workflow = run.string("workflowName") ?: "Workflow",
            title = run.string("displayTitle").orEmpty(),
            state = GitHubCheckState.from(run.string("status"), run.string("conclusion")),
            url = url(run.string("url")),
            event = run.string("event").orEmpty(),
            createdAt = date(run.string("createdAt")),
        )
    }

    /** Una ejecución por workflow (la más reciente), ordenadas por nombre. */
    fun latestPerWorkflow(runs: List<GitHubRun>): List<GitHubRun> =
        runs.groupBy { it.workflow }
            .map { (_, group) -> group.maxWith(compareBy<GitHubRun>({ it.createdAt ?: Instant.MIN }, { it.id })) }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.workflow })

    // MARK: - Repositorios y operaciones

    fun parseRepositories(output: String): GitHubRepositoriesResult {
        val fields = fields(output)
        if ("missing" in fields) return GitHubRepositoriesResult.GhMissing
        val raw = fields["repos"] ?: return GitHubRepositoriesResult.Failed("gh no devolvió la lista de repositorios.")
        return when (val classified = classify(raw)) {
            is Classified.Json -> GitHubRepositoriesResult.Loaded(
                (classified.element as? JsonArray).orEmpty().mapNotNull { item ->
                    val repo = item as? JsonObject ?: return@mapNotNull null
                    GitHubRepository(
                        nameWithOwner = repo.string("nameWithOwner") ?: return@mapNotNull null,
                        description = repo.string("description").orEmpty(),
                        isPrivate = repo["isPrivate"]?.jsonPrimitive?.booleanOrNull ?: false,
                        updatedAt = date(repo.string("updatedAt")),
                    )
                },
            )
            Classified.NotAuthenticated -> GitHubRepositoriesResult.NotAuthenticated
            Classified.NoPullRequest, Classified.NotGitHub -> GitHubRepositoriesResult.Loaded(emptyList())
            is Classified.Error -> GitHubRepositoriesResult.Failed(classified.message)
        }
    }

    /** Ruta real de la carpeta clonada (`null` si la salida no la trae). */
    fun clonedPath(output: String): String? = fields(output)["path"]?.takeIf { it.startsWith("/") }

    /** Por qué se negó el clonado (carpeta existente o padre inexistente). */
    fun cloneRefusal(output: String): String? {
        val fields = fields(output)
        return when {
            "exists" in fields -> "Ya existe una carpeta con ese nombre. Elige otro."
            "noparent" in fields -> "La carpeta donde clonar no existe en el servidor."
            else -> null
        }
    }

    /** URL que `gh pr create` imprime en su última línea. */
    fun createdPullRequestUrl(output: String): String? =
        output.lines().map { it.trim() }.lastOrNull { it.startsWith("https://") }

    private fun url(value: String?): String? = value?.takeIf { it.startsWith("https://") }

    private fun date(value: String?): Instant? = value?.let {
        try {
            Instant.parse(it)
        } catch (_: DateTimeParseException) {
            null
        }
    }
}
