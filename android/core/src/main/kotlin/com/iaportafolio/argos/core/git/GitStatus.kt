package com.iaportafolio.argos.core.git

/**
 * Estado de un repositorio git del servidor (port de `ArgosCore/Git/GitStatus.swift`): rama,
 * upstream, adelantado/atrasado y archivos cambiados. Lo parsea [GitStatusParser] a partir de
 * `git status --porcelain=v1 -z -b`.
 */
enum class GitChangeKind(
    /** Letra corta para la UI (como en `git status -s`). */
    val letter: String,
    /** Descripción para accesibilidad. */
    val label: String,
) {
    MODIFIED("M", "Modificado"),
    ADDED("A", "Añadido"),
    DELETED("D", "Eliminado"),
    RENAMED("R", "Renombrado"),
    COPIED("C", "Copiado"),
    TYPE_CHANGED("T", "Tipo cambiado"),
    UNTRACKED("U", "Nuevo, sin seguimiento"),
    CONFLICTED("!", "En conflicto"),
}

/** Un archivo con cambios respecto a `HEAD`. */
data class GitFileChange(
    /** Ruta relativa a la raíz del repositorio. */
    val path: String,
    /** Ruta anterior en un renombrado/copia. */
    val originalPath: String? = null,
    /** Columna X de porcelain (índice) e Y (árbol de trabajo), tal cual. */
    val indexCode: Char,
    val worktreeCode: Char,
) {
    val fileName: String get() = path.substringAfterLast('/')

    /** Carpeta del archivo (`""` en la raíz). */
    val directory: String get() = if ('/' in path) path.substringBeforeLast('/') else ""

    val isUntracked: Boolean get() = indexCode == '?' && worktreeCode == '?'

    /** Combinaciones de conflicto de `git status` (DD, AU, UD, UA, DU, AA, UU). */
    val isConflicted: Boolean get() = "$indexCode$worktreeCode" in CONFLICT_PAIRS

    /** Tipo de cambio dominante para mostrar (el del índice si lo hay; si no, el del árbol). */
    val kind: GitChangeKind
        get() = when {
            isUntracked -> GitChangeKind.UNTRACKED
            isConflicted -> GitChangeKind.CONFLICTED
            else -> kindOf(indexCode) ?: kindOf(worktreeCode) ?: GitChangeKind.MODIFIED
        }

    /** Rutas que afectan a un commit o a un descarte (incluye el origen de un renombrado). */
    val affectedPaths: List<String> get() = listOfNotNull(originalPath, path)

    private companion object {
        val CONFLICT_PAIRS = setOf("DD", "AU", "UD", "UA", "DU", "AA", "UU")

        fun kindOf(code: Char): GitChangeKind? = when (code) {
            'M' -> GitChangeKind.MODIFIED
            'A' -> GitChangeKind.ADDED
            'D' -> GitChangeKind.DELETED
            'R' -> GitChangeKind.RENAMED
            'C' -> GitChangeKind.COPIED
            'T' -> GitChangeKind.TYPE_CHANGED
            else -> null
        }
    }
}

/** Rama actual y su relación con el upstream. */
data class GitBranchInfo(
    /** `null` con HEAD desacoplado. */
    val name: String?,
    val upstream: String?,
    val ahead: Int,
    val behind: Int,
    /** `false` en un repositorio recién creado sin commits. */
    val hasCommits: Boolean,
    /** El upstream configurado ya no existe en el remoto. */
    val upstreamGone: Boolean,
) {
    companion object {
        val UNKNOWN = GitBranchInfo(null, null, 0, 0, hasCommits = true, upstreamGone = false)
    }
}

/** Estado completo de un repositorio. */
data class GitRepositoryStatus(
    /** Raíz absoluta del repositorio en el servidor (`git rev-parse --show-toplevel`). */
    val root: String,
    val branch: GitBranchInfo,
    val changes: List<GitFileChange>,
    /** Se recortó la lista (demasiados archivos, p. ej. un `node_modules` sin ignorar). */
    val truncated: Boolean,
) {
    val repositoryName: String get() = root.trimEnd('/').substringAfterLast('/')
    val isClean: Boolean get() = changes.isEmpty()
}

/** Resultado de consultar el estado git de una carpeta. */
sealed interface GitStatusResult {
    data object GitMissing : GitStatusResult
    data object NotRepository : GitStatusResult
    data class Repository(val status: GitRepositoryStatus) : GitStatusResult
}
