package com.iaportafolio.argos.core.git

import com.iaportafolio.argos.core.ShellQuoting

/**
 * Comandos git remotos (port de `ArgosCore/Git/GitCommands.swift`, byte a byte: los servidores
 * son los mismos que usan Mac e iPhone). Todas las rutas van entrecomilladas con [ShellQuoting]
 * y se ejecutan bajo `sh` con `git -C <raíz>`: nunca se interpola texto del usuario sin comillas.
 */
object GitCommands {

    /** Marcadores de la salida de `status` (el perfil del shell puede ensuciar el inicio). */
    const val ROOT_MARKER = "ARGOS_GIT_ROOT:"
    const val NO_GIT_MARKER = "ARGOS_NO_GIT"

    /** Límite de bytes de la salida de `status` y de un diff (evita traer megas por SSH). */
    const val STATUS_BYTE_LIMIT = 2_000_000
    const val DIFF_BYTE_LIMIT = 512_000

    /**
     * Entorno para operaciones de red: git nunca se queda esperando una contraseña en un canal
     * sin TTY (fallaría en vez de colgarse). Respeta un `GIT_SSH_COMMAND` propio.
     */
    const val NON_INTERACTIVE_ENV = "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=\"\${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}\""

    private fun q(value: String) = ShellQuoting.singleQuoted(value)

    internal fun posixShell(script: String) = "sh -c " + q(script)

    /**
     * `git` sobre [root] con rutas LITERALES: los nombres de archivo vienen del servidor (o de un
     * agente) y git interpretaría `*`, `?`, `[…]` o `:(glob)` como patrones, así que descartar el
     * archivo `*` haría `clean -f` de TODOS los no seguidos. El entrecomillado del shell no lo
     * evita: quien expande es git.
     */
    fun git(root: String) = "git --literal-pathspecs -C ${q(root)}"

    private fun pathspec(paths: List<String>) = paths.joinToString(" ") { q(it) }

    /**
     * Raíz del repo + estado porcelain en un solo round-trip. `GIT_OPTIONAL_LOCKS=0`: no toma el
     * lock del índice, así no choca con un agente que esté haciendo commits.
     */
    fun status(path: String): String = posixShell(
        """
        command -v git >/dev/null 2>&1 || { echo $NO_GIT_MARKER; exit 0; }
        top=${'$'}(git -C ${q(path)} rev-parse --show-toplevel 2>/dev/null) || exit 0
        printf '%s%s\n' '$ROOT_MARKER' "${'$'}top"
        GIT_OPTIONAL_LOCKS=0 git -C "${'$'}top" status --porcelain=v1 -z -b --untracked-files=all | head -c $STATUS_BYTE_LIMIT
        """.trimIndent(),
    )

    /**
     * Diff de un archivo frente a `HEAD` (o, sin commits, índice + árbol de trabajo). Un archivo
     * sin seguimiento se compara con `/dev/null` (`--no-index` sale con 1).
     */
    fun diff(root: String, change: GitFileChange, hasCommits: Boolean): String {
        val gitDiff = "${git(root)} -c core.quotepath=off diff --no-color --no-ext-diff"
        val body = when {
            change.isUntracked -> "$gitDiff --no-index -- /dev/null ${q(change.path)}"
            hasCommits -> "$gitDiff -M HEAD -- ${pathspec(change.affectedPaths)}"
            else -> "$gitDiff --cached -- ${q(change.path)}; $gitDiff -- ${q(change.path)}"
        }
        return posixShell("{ $body; } | head -c ${DIFF_BYTE_LIMIT + 1}")
    }

    /**
     * Descarta los cambios de un archivo: lo deja como en `HEAD` (restore en modo no-overlay: un
     * archivo que no existe en HEAD se borra) o, si no tenía seguimiento, lo elimina. Operación
     * destructiva: la UI pide confirmación.
     */
    fun discard(root: String, change: GitFileChange): String =
        if (change.isUntracked) {
            posixShell("${git(root)} clean -f -- ${q(change.path)}")
        } else {
            posixShell("${git(root)} restore --source=HEAD --staged --worktree -- ${pathspec(change.affectedPaths)}")
        }

    /**
     * Prepara y hace commit SOLO de [changes] (`commit --only` implícito con pathspec), sin
     * arrastrar lo que ya estuviera en el índice de otros archivos. `add` recibe solo la ruta
     * actual: el origen de un renombrado ya preparado (`git mv`) no existe y `add` fallaría con
     * «pathspec did not match». El commit sí lleva ambas rutas.
     */
    fun commit(root: String, message: String, changes: List<GitFileChange>): String =
        posixShell(commitScript(root, message, changes))

    /** Script de [commit] sin envolver en `sh -c` (testeable). */
    fun commitScript(root: String, message: String, changes: List<GitFileChange>): String {
        val stage = pathspec(changes.map { it.path }.distinct())
        val spec = pathspec(commitPaths(changes))
        return "${git(root)} add -A -- $stage && ${git(root)} commit -m ${q(message)} -- $spec"
    }

    /** Rutas del commit (incluye el origen de los renombrados), sin duplicados. */
    fun commitPaths(changes: List<GitFileChange>): List<String> = changes.flatMap { it.affectedPaths }.distinct()

    /** Sube la rama. Sin upstream, la publica en `origin` y lo fija (`-u`). */
    fun push(root: String, hasUpstream: Boolean): String {
        val target = if (hasUpstream) "" else " -u origin HEAD"
        return posixShell("$NON_INTERACTIVE_ENV git -C ${q(root)} push$target 2>&1")
    }

    /** Trae cambios solo si se puede avanzar sin merge (nunca deja conflictos a medias). */
    fun pull(root: String): String = posixShell("$NON_INTERACTIVE_ENV git -C ${q(root)} pull --ff-only 2>&1")
}
