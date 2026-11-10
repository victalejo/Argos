package com.iaportafolio.argos.ui.projects

import com.iaportafolio.argos.core.github.GitHubCloneRequest
import com.iaportafolio.argos.core.github.GitHubRepository

/** Repositorios del usuario de `gh` (lista del formulario «Clonar de GitHub»). */
sealed interface CloneRepositories {
    data object Idle : CloneRepositories
    data object Loading : CloneRepositories
    data object GhMissing : CloneRepositories
    data object NotAuthenticated : CloneRepositories
    data class Loaded(val repositories: List<GitHubRepository>) : CloneRepositories
    data class Failed(val message: String) : CloneRepositories
}

/**
 * «Clonar de GitHub» del formulario de nuevo proyecto (port de `GitHubCloneModel` de Apple): el
 * repositorio (escrito o elegido de los tuyos), dónde clonarlo y la carpeta, que sigue al
 * repositorio hasta que el usuario la cambia. Inmutable.
 */
data class CloneFormState(
    val repository: String = "",
    /** Carpeta del servidor DENTRO de la cual se clona. */
    val parent: String = "~",
    val folder: String = "",
    val folderEdited: Boolean = false,
    val repositories: CloneRepositories = CloneRepositories.Idle,
    /** Carpeta ya clonada: si después falla guardar el proyecto, reintentar no vuelve a clonar. */
    val clonedPath: String? = null,
) {
    fun withRepository(value: String): CloneFormState =
        copy(repository = value, folder = if (folderEdited) folder else GitHubCloneRequest.defaultFolder(value))

    fun withFolder(value: String): CloneFormState =
        copy(folder = value, folderEdited = value != GitHubCloneRequest.defaultFolder(repository))

    fun choosing(repo: GitHubRepository): CloneFormState = copy(folderEdited = false).withRepository(repo.nameWithOwner)

    /** Ruta final que se creará (para enseñarla en el formulario). */
    val destination: String get() = parent.trimEnd('/').let { base -> if (folder.isEmpty()) base else "$base/$folder" }

    val validationError: String?
        get() = try {
            GitHubCloneRequest.make(repository, parent, folder)
            null
        } catch (error: GitHubCloneRequest.InvalidException) {
            error.message
        }

    val isValid: Boolean get() = clonedPath != null || validationError == null

    fun request(): GitHubCloneRequest = GitHubCloneRequest.make(repository, parent, folder)
}
