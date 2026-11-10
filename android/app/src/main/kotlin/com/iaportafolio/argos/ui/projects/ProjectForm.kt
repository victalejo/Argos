package com.iaportafolio.argos.ui.projects

import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectDefaults
import com.iaportafolio.argos.core.projects.ProjectError
import com.iaportafolio.argos.core.tmux.SessionGrouping
import com.iaportafolio.argos.core.tmux.SessionNameValidator
import java.time.Instant

/** Comando de arranque elegido en el formulario (Apple: `CommandMode` + presets de Ajustes). */
sealed interface StartupChoice {
    /** El predeterminado de Ajustes (`startupCommand = null`). */
    data object Default : StartupChoice

    /** Un atajo de [ProjectDefaults.PRESETS] (`""` = no lanzar nada). */
    data class Preset(val command: String) : StartupChoice

    /** Texto libre ([ProjectFormState.customCommand]). */
    data object Custom : StartupChoice

    companion object {
        /** Opción que corresponde al `startupCommand` guardado de un proyecto. */
        fun of(startupCommand: String?): StartupChoice {
            if (startupCommand == null) return Default
            val trimmed = startupCommand.trim()
            return if (ProjectDefaults.PRESETS.any { it.command == trimmed }) Preset(trimmed) else Custom
        }
    }
}

/** Qué formulario se abrió (port de `ProjectFormRequest`). */
sealed interface ProjectFormMode {
    data object New : ProjectFormMode

    data class Edit(val project: Project) : ProjectFormMode

    /** «Convertir en proyecto» una sesión suelta: su nombre no cuenta como duplicado. */
    data class Convert(val sessionName: String) : ProjectFormMode
}

/**
 * Estado del formulario de proyecto (port de `ProjectFormSheet`). Valor inmutable con la
 * validación en vivo derivada; la validación definitiva la hace `ProjectLifecycle.planSave`.
 */
data class ProjectFormState(
    val mode: ProjectFormMode,
    val name: String = "",
    val group: String = "",
    val path: String = "",
    val command: StartupChoice = StartupChoice.Default,
    val customCommand: String = "",
    /** Grupos existentes en el servidor (menú de grupos). */
    val existingGroups: List<String> = emptyList(),
    /** Comando predeterminado actual (para la etiqueta «Predeterminado (…)»). */
    val defaultCommand: String = ProjectDefaults.FACTORY_STARTUP_COMMAND,
    val isSubmitting: Boolean = false,
    /** Buscando la carpeta del primer panel al convertir una sesión. */
    val isPrefilling: Boolean = false,
    /** Error al guardar (validación de `core` o fallo remoto). */
    val error: String? = null,
    /** «Clonar de GitHub» (solo al crear); `null` = carpeta existente. */
    val clone: CloneFormState? = null,
) {
    val nameError: String? get() = liveNameError(name)

    val groupError: String? get() = group.takeIf { it.isNotBlank() }?.let(::liveNameError)

    val pathError: String?
        get() = if (path.isNotBlank() && !path.trim().startsWith("/")) ProjectError.InvalidPath.message else null

    /** El grupo escrito no existe todavía: se creará al guardar. */
    val isNewGroup: Boolean get() = group.trim().let { it.isNotEmpty() && it !in existingGroups }

    val canSubmit: Boolean
        get() = !isSubmitting && name.isNotBlank() && nameError == null && groupError == null &&
            (clone?.isValid ?: path.trim().startsWith("/")) &&
            (command != StartupChoice.Custom || customCommand.isNotBlank())

    /** `null` = predeterminado; `""` = ninguno; si no, el comando (recortado). */
    val startupCommand: String?
        get() = when (command) {
            StartupChoice.Default -> null
            is StartupChoice.Preset -> command.command
            StartupChoice.Custom -> customCommand.trim()
        }

    /** Sesión suelta adoptada al convertir. */
    val adoptedSession: String? get() = (mode as? ProjectFormMode.Convert)?.sessionName

    /** Proyecto SIN validar (lo valida y normaliza `ProjectLifecycle.planSave`). */
    fun toProject(now: Instant = Instant.now()): Project {
        val original = (mode as? ProjectFormMode.Edit)?.project
        return Project(
            id = original?.id ?: Server.newId(),
            name = name,
            group = group,
            path = path,
            startupCommand = startupCommand,
            createdAt = original?.createdAt ?: now,
            // Se conserva al editar (si no, se perdería la marca de «en el Mac»).
            macCheckout = original?.macCheckout,
        )
    }

    companion object {
        fun forNew(existingGroups: List<String>, defaultCommand: String) =
            ProjectFormState(ProjectFormMode.New, existingGroups = existingGroups, defaultCommand = defaultCommand)

        fun forEdit(project: Project, existingGroups: List<String>, defaultCommand: String): ProjectFormState {
            val choice = StartupChoice.of(project.startupCommand)
            return ProjectFormState(
                mode = ProjectFormMode.Edit(project),
                name = project.name,
                group = project.group.orEmpty(),
                path = project.path,
                command = choice,
                customCommand = if (choice == StartupChoice.Custom) project.startupCommand.orEmpty() else "",
                existingGroups = existingGroups,
                defaultCommand = defaultCommand,
            )
        }

        /** Al convertir, propone nombre y grupo a partir de «grupo/nombre». */
        fun forConvert(sessionName: String, existingGroups: List<String>, defaultCommand: String): ProjectFormState {
            val (group, short) = SessionGrouping.split(sessionName)
            val hasGroup = short != sessionName
            return ProjectFormState(
                mode = ProjectFormMode.Convert(sessionName),
                name = if (hasGroup) short else sessionName,
                group = if (hasGroup) group else "",
                existingGroups = existingGroups,
                defaultCommand = defaultCommand,
                isPrefilling = true,
            )
        }

        /** Último componente de una ruta (nombre propuesto al elegir carpeta). */
        fun folderName(path: String): String = path.trimEnd('/').substringAfterLast('/')

        private fun liveNameError(raw: String): String? =
            SessionNameValidator.liveValidationMessage(raw)
                ?: if (SessionGrouping.SEPARATOR in raw) {
                    SessionNameValidator.ValidationError.ForbiddenCharacter(SessionGrouping.SEPARATOR).message
                } else {
                    null
                }
    }
}
