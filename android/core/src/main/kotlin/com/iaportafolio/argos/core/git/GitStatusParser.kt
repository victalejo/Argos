package com.iaportafolio.argos.core.git

/**
 * Parser puro de la salida de [GitCommands.status] (port de `GitStatusParser.swift`): primera
 * línea = marcador o raíz del repo; después, `git status --porcelain=v1 -z -b` (entradas
 * separadas por NUL).
 */
object GitStatusParser {

    /** Máximo de archivos que se muestran (el resto se marca como recortado). */
    const val MAX_CHANGES = 2000

    fun parse(output: String): GitStatusResult {
        // El perfil del shell puede ensuciar el principio: se busca la línea marcadora.
        val markerAt = output.indexOf(GitCommands.ROOT_MARKER)
        if (markerAt < 0) {
            return if (GitCommands.NO_GIT_MARKER in output) GitStatusResult.GitMissing else GitStatusResult.NotRepository
        }
        val afterMarker = output.substring(markerAt + GitCommands.ROOT_MARKER.length)
        val newline = afterMarker.indexOf('\n')
        if (newline < 0) return GitStatusResult.NotRepository
        val root = afterMarker.substring(0, newline).trim(' ', '\t')
        if (!root.startsWith("/")) return GitStatusResult.NotRepository
        return GitStatusResult.Repository(parsePorcelain(afterMarker.substring(newline + 1), root))
    }

    /** Parsea la parte porcelain (`-z -b`). */
    fun parsePorcelain(body: String, root: String): GitRepositoryStatus {
        val fields = body.split('\u0000').toMutableList()
        // Un `-z` termina en NUL: el último campo vacío (o cortado por `head -c`) sobra.
        if (fields.isNotEmpty() && (fields.last().isEmpty() || !body.endsWith('\u0000'))) fields.removeAt(fields.lastIndex)

        var branch = GitBranchInfo.UNKNOWN
        val changes = mutableListOf<GitFileChange>()
        var truncated = !body.endsWith('\u0000') && body.isNotEmpty()
        var index = 0
        while (index < fields.size) {
            val field = fields[index]
            index += 1
            if (field.startsWith("## ")) {
                branch = parseBranch(field.substring(3))
                continue
            }
            val entry = parseEntry(field) ?: continue
            var original: String? = null
            if (entry.needsOriginal) {
                if (index >= fields.size) break
                original = fields[index]
                index += 1
            }
            if (changes.size >= MAX_CHANGES) {
                truncated = true
                continue
            }
            changes += GitFileChange(entry.path, original, entry.x, entry.y)
        }
        return GitRepositoryStatus(root, branch, changes, truncated)
    }

    private class Entry(val x: Char, val y: Char, val path: String) {
        val needsOriginal: Boolean get() = x == 'R' || x == 'C' || y == 'R' || y == 'C'
    }

    /** `XY ruta` (dos letras de estado, un espacio y la ruta). */
    private fun parseEntry(field: String): Entry? {
        if (field.codePointCount(0, field.length) < 4 || field[2] != ' ') return null
        return Entry(field[0], field[1], field.substring(3))
    }

    /**
     * Cabecera `-b`. Formas:
     *  - `main`
     *  - `main...origin/main [ahead 1, behind 2]`
     *  - `main...origin/main [gone]`
     *  - `No commits yet on main` / `Initial commit on main` (git antiguo)
     *  - `HEAD (no branch)`
     */
    fun parseBranch(header: String): GitBranchInfo {
        for (prefix in listOf("No commits yet on ", "Initial commit on ")) {
            if (header.startsWith(prefix)) {
                return GitBranchInfo(header.removePrefix(prefix), null, 0, 0, hasCommits = false, upstreamGone = false)
            }
        }
        if (header.startsWith("HEAD (no branch)")) {
            return GitBranchInfo(null, null, 0, 0, hasCommits = true, upstreamGone = false)
        }

        var refs = header
        var tracking = ""
        val bracket = header.lastIndexOf(" [")
        if (bracket >= 0 && header.endsWith("]")) {
            refs = header.substring(0, bracket)
            tracking = header.substring(bracket + 2, header.length - 1)
        }
        val parts = refs.split("...")
        val name = parts[0]
        return GitBranchInfo(
            name = name.ifEmpty { null },
            upstream = parts.getOrNull(1),
            ahead = count("ahead", tracking),
            behind = count("behind", tracking),
            hasCommits = true,
            upstreamGone = tracking == "gone",
        )
    }

    private fun count(word: String, tracking: String): Int {
        for (item in tracking.split(", ")) {
            val pieces = item.split(' ').filter { it.isNotEmpty() }
            if (pieces.size == 2 && pieces[0] == word) pieces[1].toIntOrNull()?.let { return it }
        }
        return 0
    }
}
