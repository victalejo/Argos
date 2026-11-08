package com.iaportafolio.argos.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.iaportafolio.argos.core.projects.CollapsedSessionGroups
import com.iaportafolio.argos.core.projects.ProjectDefaults
import com.iaportafolio.argos.core.projects.ProjectStatusFilter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Preferencias locales de la lista de proyectos (no son secretos). */
data class ProjectPreferences(
    val collapsed: CollapsedSessionGroups = CollapsedSessionGroups(),
    val statusFilter: ProjectStatusFilter = ProjectStatusFilter.ALL,
    /** Comando de arranque predeterminado (Apple: `projects.defaultStartupCommand`). */
    val defaultStartupCommand: String = ProjectDefaults.FACTORY_STARTUP_COMMAND,
)

interface ProjectPreferencesStore {
    val preferences: StateFlow<ProjectPreferences>
    fun toggleCollapsed(serverId: String, group: String)
    fun setStatusFilter(filter: ProjectStatusFilter)
}

/** [ProjectPreferencesStore] sobre `SharedPreferences`, con las mismas claves que Apple. */
class SharedPreferencesProjectPreferences(context: Context) : ProjectPreferencesStore {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private val state = MutableStateFlow(
        ProjectPreferences(
            collapsed = CollapsedSessionGroups(prefs.getStringSet(CollapsedSessionGroups.DEFAULTS_KEY, null).orEmpty().toSet()),
            statusFilter = prefs.getString(KEY_FILTER, null)?.let(ProjectStatusFilter::fromId) ?: ProjectStatusFilter.ALL,
            defaultStartupCommand = prefs.getString(ProjectDefaults.DEFAULTS_KEY, null) ?: ProjectDefaults.FACTORY_STARTUP_COMMAND,
        ),
    )
    override val preferences: StateFlow<ProjectPreferences> = state.asStateFlow()

    override fun toggleCollapsed(serverId: String, group: String) {
        val updated = state.value.collapsed.toggled(serverId, group)
        state.update { it.copy(collapsed = updated) }
        prefs.edit { putStringSet(CollapsedSessionGroups.DEFAULTS_KEY, updated.keys) }
    }

    override fun setStatusFilter(filter: ProjectStatusFilter) {
        state.update { it.copy(statusFilter = filter) }
        prefs.edit { putString(KEY_FILTER, filter.id) }
    }

    private companion object {
        const val FILE = "projects"
        const val KEY_FILTER = "projects.statusFilter"
    }
}
