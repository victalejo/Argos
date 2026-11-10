package com.iaportafolio.argos.core.git

import com.iaportafolio.argos.core.ShellQuoting

/**
 * Resumen git de VARIOS proyectos en un solo round-trip SSH (port de `GitRepoSummary.swift`):
 * rama, adelantado/atrasado y cuántos archivos cambiados. Lo usa la lista de proyectos (insignia
 * ↑2 ✎5) y el aviso «Claude terminó · N archivos cambiados».
 */
data class GitRepoSummary(
    val branch: GitBranchInfo,
    /** Archivos con cambios (las carpetas sin seguimiento cuentan como una entrada). */
    val changedCount: Int,
) {
    val isClean: Boolean get() = changedCount == 0

    /** Hay algo que mostrar en la fila (cambios o commits por subir/bajar). */
    val isNoteworthy: Boolean get() = changedCount > 0 || branch.ahead > 0 || branch.behind > 0

    /** Texto corto para accesibilidad («rama main, 5 archivos cambiados, 2 commits por subir»). */
    val label: String
        get() = buildList {
            add("rama ${branch.name ?: "HEAD desacoplado"}")
            if (changedCount > 0) add("$changedCount ${plural(changedCount, "archivo")} ${plural(changedCount, "cambiado")}")
            if (branch.ahead > 0) add("${branch.ahead} ${plural(branch.ahead, "commit")} por subir")
            if (branch.behind > 0) add("${branch.behind} ${plural(branch.behind, "commit")} por traer")
            if (!isNoteworthy) add("sin cambios")
        }.joinToString(", ")
}

private fun plural(count: Int, word: String) = if (count == 1) word else "${word}s"

object GitSummaryCommands {

    /** Prefijo de cada línea de resultado (el perfil del shell puede ensuciar la salida). */
    const val MARKER = "ARGOS_GSUM"

    /** Segundos máximos por repositorio (un repo enorme no bloquea a los demás). */
    const val PER_REPO_TIMEOUT = 5

    /**
     * Una línea por ruta: `ARGOS_GSUM <i> <n> <cabecera -b>` o `ARGOS_GSUM <i> -` si no es un
     * repositorio. `GIT_OPTIONAL_LOCKS=0`: no toma el lock del índice. Las carpetas sin
     * seguimiento no se expanden (`--untracked-files=normal`): basta para contar.
     */
    fun summaries(paths: List<String>): String {
        val list = paths.joinToString(" ") { ShellQuoting.singleQuoted(it) }
        return GitCommands.posixShell(
            """
            command -v git >/dev/null 2>&1 || exit 0
            t=''; command -v timeout >/dev/null 2>&1 && t='timeout $PER_REPO_TIMEOUT'
            i=0
            for p in $list; do
              out=${'$'}(GIT_OPTIONAL_LOCKS=0 ${'$'}t git -C "${'$'}p" status --porcelain=v1 -b --untracked-files=normal 2>/dev/null)     || { printf '%s %s -\n' $MARKER "${'$'}i"; i=${'$'}((i+1)); continue; }
              n=${'$'}(printf '%s\n' "${'$'}out" | sed 1d | grep -c .)
              h=${'$'}(printf '%s\n' "${'$'}out" | sed -n 1p)
              printf '%s %s %s %s\n' $MARKER "${'$'}i" "${'$'}n" "${'$'}h"
              i=${'$'}((i+1))
            done
            """.trimIndent(),
        )
    }
}

object GitSummaryParser {

    /** Resúmenes por ruta (las que no son repositorio no aparecen). */
    fun parse(output: String, paths: List<String>): Map<String, GitRepoSummary> {
        val result = mutableMapOf<String, GitRepoSummary>()
        val prefix = GitSummaryCommands.MARKER + " "
        for (line in output.lines()) {
            if (!line.startsWith(prefix)) continue
            val fields = line.removePrefix(prefix).split(' ', limit = 3)
            if (fields.size != 3) continue
            val index = fields[0].toIntOrNull()?.takeIf { it in paths.indices } ?: continue
            val count = fields[1].toIntOrNull() ?: continue
            val header = fields[2].trimEnd('\r')
            if (!header.startsWith("## ")) continue
            result[paths[index]] = GitRepoSummary(GitStatusParser.parseBranch(header.substring(3)), count)
        }
        return result
    }
}

/**
 * Texto del aviso «Claude terminó», con los archivos cambiados del proyecto si se conocen: así
 * se sabe de un vistazo si hay algo que revisar (mismo texto que Mac e iPhone/iPad).
 */
object ClaudeDoneMessage {
    fun body(changedFiles: Int?): String {
        if (changedFiles == null || changedFiles <= 0) return "Terminó de responder."
        val files = "$changedFiles ${plural(changedFiles, "archivo")} ${plural(changedFiles, "cambiado")}"
        return "Terminó de responder · $files. Revísalos en «Cambios»."
    }
}
