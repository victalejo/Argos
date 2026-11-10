package com.iaportafolio.argos.core.git

import com.iaportafolio.argos.core.ShellQuoting

/**
 * «Ramas en paralelo»: worktrees de git en el servidor (port de `ArgosCore/Git/GitWorktree.swift`
 * y `GitWorktreeCommands.swift`). Cada worktree es una carpeta con su rama; en Argos, un proyecto
 * normal (sin cambiar el formato de `projects.json`).
 */
data class GitWorktree(
    val path: String,
    val head: String,
    /** `null` con HEAD desacoplado. */
    val branch: String?,
    /** El worktree principal (el repositorio original): no se puede quitar. */
    val isMain: Boolean,
    val isLocked: Boolean,
    /** git cree que su carpeta ya no existe. */
    val isPrunable: Boolean,
    /** Archivos con cambios sin confirmar (`null` si no se pudo saber). */
    val changedCount: Int? = null,
) {
    val displayBranch: String get() = branch ?: "HEAD desacoplado (${head.take(7)})"
}

/** Worktrees del repositorio y sus ramas locales. */
data class GitWorktreeListing(val worktrees: List<GitWorktree>, val branches: List<String>) {
    val main: GitWorktree? get() = worktrees.firstOrNull { it.isMain }

    /** Ramas que no están ya en algún worktree (git no deja tener la misma en dos). */
    val freeBranches: List<String>
        get() {
            val used = worktrees.mapNotNull { it.branch }.toSet()
            return branches.filter { it !in used }
        }

    /** Carpeta por defecto: hermana del repo, `app-worktrees/rama`. */
    fun defaultPath(branch: String): String? {
        val main = main ?: return null
        val parent = main.path.substringBeforeLast('/', "")
        val repo = main.path.substringAfterLast('/')
        return "$parent/$repo-worktrees/${GitBranchName.slug(branch)}"
    }
}

/** Reglas de nombre de rama (lo esencial de `git check-ref-format --branch`; git lo revalida). */
object GitBranchName {
    private val FORBIDDEN = setOf(' ', '~', '^', ':', '?', '*', '[', '\\')

    fun isValid(name: String): Boolean {
        if (name.isEmpty() || name.startsWith("-") || name.startsWith("/") || name.endsWith("/")) return false
        if (name.endsWith(".") || name.endsWith(".lock") || name == "@" || name.startsWith(".")) return false
        if (listOf("..", "//", "@{", "/.").any { it in name }) return false
        return name.none { it in FORBIDDEN || it.isWhitespace() || it.isISOControl() }
    }

    /** Para carpetas: `feat/login` → `feat-login`. */
    fun slug(branch: String): String = branch.replace('/', '-')

    /** Para el nombre del proyecto (y su sesión tmux, que no admite «.» ni «:»). */
    fun projectSlug(branch: String): String = slug(branch).replace('.', '-')
}

/** Petición validada de worktree nuevo. */
data class GitWorktreeRequest(
    /** Raíz del worktree principal (desde ella se ejecuta `git worktree`). */
    val repository: String,
    val branch: String,
    /** `true`: crea la rama desde [base]; `false`: usa una rama local existente. */
    val createsBranch: Boolean,
    val base: String,
    /** Carpeta ABSOLUTA del worktree (no debe existir). */
    val path: String,
) {
    /** Error de validación con su mensaje para el usuario (mismos textos que Apple). */
    class InvalidException(message: String) : IllegalArgumentException(message)

    companion object {
        const val INVALID_BRANCH = "Ese nombre de rama no es válido (sin espacios, «..», «~», «^», «:» ni «-» al principio)."
        const val BRANCH_EXISTS = "Esa rama ya existe: elige «Rama existente» para abrirla."
        const val BRANCH_IN_USE = "Esa rama ya está abierta en otro worktree: git no deja tenerla en dos a la vez."
        const val INVALID_BASE = "Elige desde qué rama nace la nueva."
        const val INVALID_PATH = "La carpeta debe ser una ruta completa que empiece por /."

        fun make(listing: GitWorktreeListing, branch: String, createsBranch: Boolean, base: String, path: String): GitWorktreeRequest {
            val name = branch.trim()
            val from = base.trim()
            val folder = path.trim()
            if (!GitBranchName.isValid(name)) throw InvalidException(INVALID_BRANCH)
            if (createsBranch) {
                if (name in listing.branches) throw InvalidException(BRANCH_EXISTS)
                if (from != "HEAD" && !GitBranchName.isValid(from)) throw InvalidException(INVALID_BASE)
            } else if (name !in listing.freeBranches) {
                throw InvalidException(BRANCH_IN_USE)
            }
            if (!folder.startsWith("/") || "/../" in folder || folder.endsWith("/..")) throw InvalidException(INVALID_PATH)
            val main = listing.main ?: throw InvalidException(INVALID_PATH)
            return GitWorktreeRequest(main.path, name, createsBranch, from, folder)
        }
    }
}

/** Comandos de worktrees, byte a byte los de Swift (golden en los tests). */
object GitWorktreeCommands {
    const val MARKER = "ARGOS_WT:"
    const val REFUSED_EXIT_CODE = 3

    private fun q(value: String) = ShellQuoting.singleQuoted(value)

    fun list(path: String): String = GitCommands.posixShell(
        """
        command -v git >/dev/null 2>&1 || { echo ${MARKER}nogit; exit 0; }
        git -C ${q(path)} rev-parse --git-dir >/dev/null 2>&1 || { echo ${MARKER}norepo; exit 0; }
        echo ${MARKER}list
        git -C ${q(path)} worktree list --porcelain
        echo ${MARKER}end
        git -C ${q(path)} worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r w; do
          n=${'$'}(GIT_OPTIONAL_LOCKS=0 git -C "${'$'}w" status --porcelain 2>/dev/null | grep -c .)
          printf '%sdirty %s %s\n' $MARKER "${'$'}n" "${'$'}w"
        done
        git -C ${q(path)} for-each-ref --format='${MARKER}branch %(refname:short)' refs/heads
        """.trimIndent(),
    )

    fun add(request: GitWorktreeRequest): String {
        val git = "git -C ${q(request.repository)}"
        val target = if (request.createsBranch) {
            "-b ${q(request.branch)} \"${'$'}d\" ${q(request.base)}"
        } else {
            "\"${'$'}d\" ${q(request.branch)}"
        }
        return GitCommands.posixShell(
            """
            $git check-ref-format --branch ${q(request.branch)} >/dev/null 2>&1 || { echo ${MARKER}badbranch; exit $REFUSED_EXIT_CODE; }
            d=${q(request.path)}
            [ -e "${'$'}d" ] && { echo ${MARKER}exists; exit $REFUSED_EXIT_CODE; }
            mkdir -p "${'$'}(dirname "${'$'}d")" || exit ${'$'}?
            $git worktree add $target 2>&1 || exit ${'$'}?
            cd "${'$'}d" && printf '%spath %s\n' $MARKER "${'$'}(pwd -P)"
            """.trimIndent(),
        )
    }

    /** Quita el worktree; la rama NO se borra. */
    fun remove(repository: String, path: String, force: Boolean): String =
        GitCommands.posixShell("git -C ${q(repository)} worktree remove${if (force) " --force" else ""} ${q(path)} 2>&1")
}

/** Resultado de listar los worktrees. */
sealed interface GitWorktreeListResult {
    data object GitMissing : GitWorktreeListResult
    data object NotRepository : GitWorktreeListResult
    data class Loaded(val listing: GitWorktreeListing) : GitWorktreeListResult
}

object GitWorktreeParser {

    fun parseList(output: String): GitWorktreeListResult {
        val lines = output.split('\n').map { it.trimEnd('\r') }
        val marker = GitWorktreeCommands.MARKER
        if (lines.any { it.endsWith("${marker}nogit") }) return GitWorktreeListResult.GitMissing
        val start = lines.indexOfFirst { it.endsWith("${marker}list") }
        if (start < 0) return GitWorktreeListResult.NotRepository
        val end = (start until lines.size).firstOrNull { lines[it].endsWith("${marker}end") } ?: lines.size
        val worktrees = parsePorcelain(lines.subList(start + 1, end))

        val dirty = mutableMapOf<String, Int>()
        val branches = mutableListOf<String>()
        for (line in lines.drop(end)) {
            val at = line.indexOf(marker)
            if (at < 0) continue
            val rest = line.substring(at + marker.length)
            when {
                rest.startsWith("dirty ") -> {
                    val fields = rest.removePrefix("dirty ").split(' ', limit = 2)
                    val count = fields.getOrNull(0)?.toIntOrNull()
                    if (fields.size == 2 && count != null) dirty[fields[1]] = count
                }
                rest.startsWith("branch ") -> branches += rest.removePrefix("branch ")
            }
        }
        return GitWorktreeListResult.Loaded(GitWorktreeListing(worktrees.map { it.copy(changedCount = dirty[it.path]) }, branches))
    }

    /** Bloques del porcelain separados por línea vacía; el primero es el principal (salvo repo bare). */
    fun parsePorcelain(lines: List<String>): List<GitWorktree> {
        val result = mutableListOf<GitWorktree>()
        var path: String? = null
        var head = ""
        var branch: String? = null
        var bare = false
        var locked = false
        var prunable = false
        var blocks = 0
        var bareFirst = false

        fun flush() {
            val current = path
            if (current != null) {
                blocks += 1
                if (bare) {
                    if (blocks == 1) bareFirst = true
                } else {
                    result += GitWorktree(current, head, branch, blocks == 1 && !bareFirst, locked, prunable)
                }
            }
            path = null
            head = ""
            branch = null
            bare = false
            locked = false
            prunable = false
        }

        for (line in lines) {
            when {
                line.isEmpty() -> flush()
                line.startsWith("worktree ") -> {
                    if (path != null) flush()
                    path = line.removePrefix("worktree ")
                }
                line.startsWith("HEAD ") -> head = line.removePrefix("HEAD ")
                line.startsWith("branch ") -> branch = line.removePrefix("branch ").removePrefix("refs/heads/")
                line == "bare" -> bare = true
                line == "locked" || line.startsWith("locked ") -> locked = true
                line == "prunable" || line.startsWith("prunable ") -> prunable = true
            }
        }
        flush()
        return result
    }

    fun addedPath(output: String): String? = output.lines().firstNotNullOfOrNull { line ->
        val at = line.indexOf("${GitWorktreeCommands.MARKER}path ")
        if (at < 0) null else line.substring(at + GitWorktreeCommands.MARKER.length + 5).trim().takeIf { it.startsWith("/") }
    }

    fun addRefusal(output: String): String? = when {
        "${GitWorktreeCommands.MARKER}badbranch" in output -> GitWorktreeRequest.INVALID_BRANCH
        "${GitWorktreeCommands.MARKER}exists" in output -> "Ya existe una carpeta en esa ruta. Elige otra."
        else -> null
    }
}
