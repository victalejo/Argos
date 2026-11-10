package com.iaportafolio.argos.core.github

import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand

/**
 * Comandos `gh` remotos (port de `ArgosCore/GitHub/GitHubCommands.swift`, byte a byte: el golden
 * de los tests lo generó el código Swift). Corren en el SERVIDOR con su sesión de `gh`.
 */
object GitHubCommands {

    /** Prefijo de las líneas de resultado (el perfil del shell puede ensuciar la salida). */
    const val MARKER = "ARGOS_GH:"

    /** Segundos máximos de cada llamada de `gh` de consulta. */
    const val QUERY_TIMEOUT = 20

    /** Entorno de `gh`: sin prompts, sin colores ni avisos de versión nueva. */
    const val ENV = "GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GIT_TERMINAL_PROMPT=0"

    const val PR_FIELDS = "number,title,url,state,isDraft,reviewDecision,statusCheckRollup"
    const val RUN_FIELDS = "databaseId,status,conclusion,workflowName,displayTitle,url,headSha,event,createdAt"
    const val REPO_FIELDS = "nameWithOwner,description,isPrivate,updatedAt"

    /** Exit code de [clone] cuando la carpeta destino ya existe o falta la carpeta padre. */
    const val CLONE_REFUSED_EXIT_CODE = 3

    private fun q(value: String) = ShellQuoting.singleQuoted(value)

    private fun posixShell(script: String) = "sh -c " + q(script)

    private const val TIMEOUT_PREFIX =
        "t=''; command -v timeout >/dev/null 2>&1 && t='timeout $QUERY_TIMEOUT'"

    /** PR de la rama actual + ejecuciones de Actions de HEAD, en un solo round-trip. */
    fun status(root: String): String = posixShell(
        """
        command -v gh >/dev/null 2>&1 || { echo ${MARKER}missing; exit 0; }
        cd ${q(root)} 2>/dev/null || exit 0
        $TIMEOUT_PREFIX
        sha=${'$'}(git rev-parse HEAD 2>/dev/null)
        b=${'$'}(git symbolic-ref --quiet --short HEAD 2>/dev/null)
        printf '%ssha %s\n' $MARKER "${'$'}sha"
        printf '%sbranch %s\n' $MARKER "${'$'}b"
        if [ -n "${'$'}b" ]; then
          printf '%spr ' $MARKER; $ENV ${'$'}t gh pr view "${'$'}b" --json $PR_FIELDS 2>&1 | tr '\n' ' '; echo
        fi
        if [ -n "${'$'}sha" ]; then
          printf '%sruns ' $MARKER; $ENV ${'$'}t gh run list --commit "${'$'}sha" --limit 30 --json $RUN_FIELDS 2>&1 | tr '\n' ' '; echo
        fi
        """.trimIndent(),
    )

    /** Abre un PR de la rama actual con título y cuerpo de sus commits (`--fill`). */
    fun createPullRequest(root: String, draft: Boolean): String =
        posixShell("cd ${q(root)} && $ENV gh pr create --fill${if (draft) " --draft" else ""} 2>&1")

    /** Vuelve a lanzar solo los jobs fallidos de una ejecución. */
    fun rerunFailed(root: String, runId: Long): String =
        posixShell("cd ${q(root)} && $ENV gh run rerun $runId --failed 2>&1")

    /** Repositorios del usuario con sesión en `gh`. */
    fun repositories(limit: Int = 200): String = posixShell(
        """
        command -v gh >/dev/null 2>&1 || { echo ${MARKER}missing; exit 0; }
        $TIMEOUT_PREFIX
        printf '%srepos ' $MARKER; $ENV ${'$'}t gh repo list --limit $limit --json $REPO_FIELDS 2>&1 | tr '\n' ' '; echo
        """.trimIndent(),
    )

    /** Clona en `parent/folder` y escribe la ruta real resultante. Nunca pisa una carpeta existente. */
    fun clone(request: GitHubCloneRequest): String {
        val parent = ClaudeAgentCommand.cdTarget(request.parent)
        return posixShell(
            """
            p=$parent
            [ -d "${'$'}p" ] || { echo ${MARKER}noparent; exit $CLONE_REFUSED_EXIT_CODE; }
            d="${'$'}p"/${q(request.folder)}
            [ -e "${'$'}d" ] && { echo ${MARKER}exists; exit $CLONE_REFUSED_EXIT_CODE; }
            $ENV gh repo clone ${q(request.repository)} "${'$'}d" -- --quiet 2>&1 || exit ${'$'}?
            cd "${'$'}d" && printf '%spath %s\n' $MARKER "${'$'}(pwd -P)"
            """.trimIndent(),
        )
    }
}

/** Petición validada de clonado: el repositorio (`dueño/nombre` o URL) y la carpeta. */
data class GitHubCloneRequest(val repository: String, val parent: String, val folder: String) {

    /** Error de validación con su mensaje para el usuario. */
    class InvalidException(message: String) : IllegalArgumentException(message)

    companion object {
        const val INVALID_REPOSITORY = "Escribe el repositorio como «dueño/nombre» o pega su URL de GitHub."
        const val INVALID_FOLDER = "El nombre de la carpeta no puede estar vacío ni contener «/»."
        const val MISSING_PARENT = "Elige la carpeta del servidor donde clonarlo."

        private val PART = Regex("[A-Za-z0-9_.-]+")

        /** Valida y normaliza. El repositorio nunca empieza por `-` (sería una opción de `gh`). */
        fun make(repository: String, parent: String, folder: String): GitHubCloneRequest {
            val repo = repository.trim()
            val dir = folder.trim()
            val base = parent.trim()
            if (!isValidRepository(repo)) throw InvalidException(INVALID_REPOSITORY)
            if (dir.isEmpty() || '/' in dir || dir == "." || dir == ".." || dir.startsWith("-")) {
                throw InvalidException(INVALID_FOLDER)
            }
            if (base.isEmpty()) throw InvalidException(MISSING_PARENT)
            return GitHubCloneRequest(repo, base, dir)
        }

        fun isValidRepository(value: String): Boolean {
            if (value.startsWith("https://") || value.startsWith("git@")) return value.none { it.isWhitespace() }
            val parts = value.split('/')
            return parts.size == 2 && parts.all { part ->
                part.isNotEmpty() && !part.startsWith("-") && part != "." && part != ".." && PART.matches(part)
            }
        }

        /** Carpeta por defecto: el último componente sin `.git` (`dueño/app.git` → `app`). */
        fun defaultFolder(repository: String): String {
            val name = repository.trim().trimEnd('/').split('/', ':').lastOrNull().orEmpty()
            return name.removeSuffix(".git")
        }
    }
}
