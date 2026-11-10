package com.iaportafolio.argos.core.git

/**
 * Diff unificado de un archivo, ya parseado en líneas con su tipo y sus números de línea (port de
 * `ArgosCore/Git/GitDiff.swift`). Lo produce [GitDiffParser] a partir de `git diff`.
 */
enum class GitDiffLineKind {
    /** Cabeceras previas al primer hunk (`diff --git`, `index`, `---`, `+++`, modos…). */
    META,

    /** `@@ -a,b +c,d @@ contexto`. */
    HUNK,
    CONTEXT,
    ADDED,
    REMOVED,

    /** `\ No newline at end of file`. */
    NO_NEWLINE,
}

data class GitDiffLine(
    val id: Int,
    val kind: GitDiffLineKind,
    /** Texto sin el prefijo `+`/`-`/` ` (las cabeceras y hunks van completos). */
    val text: String,
    val oldNumber: Int? = null,
    val newNumber: Int? = null,
)

data class GitFileDiff(
    val lines: List<GitDiffLine>,
    val isBinary: Boolean,
    /** La salida superó el límite y se recortó. */
    val truncated: Boolean,
) {
    val additions: Int get() = lines.count { it.kind == GitDiffLineKind.ADDED }
    val deletions: Int get() = lines.count { it.kind == GitDiffLineKind.REMOVED }

    /** Sin hunks: p. ej. solo cambió el modo del archivo. */
    val hasContent: Boolean get() = lines.any { it.kind == GitDiffLineKind.HUNK }

    companion object {
        val EMPTY = GitFileDiff(emptyList(), isBinary = false, truncated = false)
    }
}

object GitDiffParser {

    fun parse(output: String, truncated: Boolean = false): GitFileDiff {
        val lines = mutableListOf<GitDiffLine>()
        var isBinary = false
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        val rawLines = output.split('\n').toMutableList()
        if (rawLines.last() == "") rawLines.removeAt(rawLines.lastIndex)
        // Si se recortó, la última línea puede estar a medias: se descarta.
        if (truncated && rawLines.isNotEmpty()) rawLines.removeAt(rawLines.lastIndex)

        for (raw in rawLines) {
            val id = lines.size
            if (raw.startsWith("diff --git ") || raw.startsWith("diff --cc ")) {
                inHunk = false
                lines += GitDiffLine(id, GitDiffLineKind.META, raw)
                continue
            }
            if (raw.startsWith("@@")) {
                hunkStarts(raw)?.let { (old, new) ->
                    oldLine = old
                    newLine = new
                    inHunk = true
                }
                lines += GitDiffLine(id, GitDiffLineKind.HUNK, raw)
                continue
            }
            if (!inHunk) {
                if (raw.startsWith("Binary files ") || raw.startsWith("GIT binary patch")) isBinary = true
                lines += GitDiffLine(id, GitDiffLineKind.META, raw)
                continue
            }
            when (raw.firstOrNull()) {
                '+' -> lines += GitDiffLine(id, GitDiffLineKind.ADDED, raw.substring(1), newNumber = newLine++)
                '-' -> lines += GitDiffLine(id, GitDiffLineKind.REMOVED, raw.substring(1), oldNumber = oldLine++)
                '\\' -> lines += GitDiffLine(id, GitDiffLineKind.NO_NEWLINE, raw)
                // Contexto (` texto`) o línea vacía de contexto que algún git deja sin espacio.
                else -> lines += GitDiffLine(id, GitDiffLineKind.CONTEXT, raw.drop(1), oldLine++, newLine++)
            }
        }
        return GitFileDiff(lines, isBinary, truncated)
    }

    /** Números iniciales de `@@ -a[,b] +c[,d] @@`. */
    fun hunkStarts(header: String): Pair<Int, Int>? {
        val parts = header.split(' ').filter { it.isNotEmpty() }
        if (parts.size < 3 || !parts[1].startsWith("-") || !parts[2].startsWith("+")) return null
        val old = parts[1].drop(1).split(',')[0].toIntOrNull() ?: return null
        val new = parts[2].drop(1).split(',')[0].toIntOrNull() ?: return null
        return old to new
    }
}
