package com.iaportafolio.argos.ui.git

import com.iaportafolio.argos.core.git.GitFileChange
import com.iaportafolio.argos.core.git.GitFileDiff
import com.iaportafolio.argos.core.git.GitRepositoryStatus
import com.iaportafolio.argos.ui.common.UiText

/** Estado del repositorio en el panel (port de `GitPanelState`). */
sealed interface GitPanelLoad {
    data object Loading : GitPanelLoad
    data object GitMissing : GitPanelLoad
    data object NotRepository : GitPanelLoad
    data class Loaded(val status: GitRepositoryStatus) : GitPanelLoad
    data class Failed(val message: UiText) : GitPanelLoad
}

/** Diff del archivo seleccionado (port de `GitDiffState`). */
sealed interface GitDiffLoad {
    data object None : GitDiffLoad
    data object Loading : GitDiffLoad
    data class Loaded(val diff: GitFileDiff) : GitDiffLoad
    data class Failed(val message: UiText) : GitDiffLoad
}

/** Operación en curso (deshabilita los botones y muestra progreso). */
sealed interface GitOperation {
    data object Commit : GitOperation
    data object Push : GitOperation
    data object Pull : GitOperation
    data object Suggest : GitOperation
    data class Discard(val path: String) : GitOperation
}

/**
 * Panel «Cambios» de un proyecto (port del estado de `GitChangesModel`): lo derivado (qué entra
 * en el commit, si se puede subir o traer) se calcula aquí, igual que en Apple.
 */
data class GitChangesUiState(
    val path: String,
    val load: GitPanelLoad = GitPanelLoad.Loading,
    val selectedPath: String? = null,
    val diff: GitDiffLoad = GitDiffLoad.None,
    /** Archivos que el usuario desmarcó del próximo commit (por defecto entran todos). */
    val excludedPaths: Set<String> = emptySet(),
    val operation: GitOperation? = null,
    val commitMessage: String = "",
    /** Archivo pendiente de confirmar su descarte (operación destructiva). */
    val confirmDiscard: GitFileChange? = null,
    /** Último resultado correcto o fallo de una operación; la UI lo muestra y lo borra. */
    val message: UiText? = null,
) {
    val status: GitRepositoryStatus? get() = (load as? GitPanelLoad.Loaded)?.status

    val changes: List<GitFileChange> get() = status?.changes.orEmpty()

    val selectedChange: GitFileChange? get() = selectedPath?.let { path -> changes.firstOrNull { it.path == path } }

    fun isIncluded(change: GitFileChange): Boolean = change.path !in excludedPaths

    val includedChanges: List<GitFileChange> get() = includedChanges(changes, excludedPaths)

    val includedCount: Int get() = includedChanges.size

    val hasConflicts: Boolean get() = changes.any { it.isConflicted }

    val canCommit: Boolean
        get() = operation == null && !hasConflicts && includedCount > 0 && commitMessage.isNotBlank()

    /** «Sugerir mensaje»: Claude lo propone a partir del diff de lo marcado. */
    val canSuggestMessage: Boolean get() = operation == null && includedCount > 0

    val canPush: Boolean
        get() {
            val branch = status?.branch ?: return false
            if (operation != null || branch.name == null || !branch.hasCommits) return false
            return branch.upstream == null || branch.ahead > 0
        }

    val canPull: Boolean
        get() {
            val branch = status?.branch ?: return false
            return operation == null && branch.upstream != null && !branch.upstreamGone
        }

    companion object {
        /** Archivos que entran en el commit (los no desmarcados). */
        fun includedChanges(changes: List<GitFileChange>, excluded: Set<String>): List<GitFileChange> =
            changes.filter { it.path !in excluded }
    }
}
