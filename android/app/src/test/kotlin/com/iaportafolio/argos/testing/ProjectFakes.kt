package com.iaportafolio.argos.testing

import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.core.projects.ProjectStatusFilter
import com.iaportafolio.argos.data.ProjectPreferences
import com.iaportafolio.argos.data.ProjectPreferencesStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.time.Instant

/** UUIDs fijos en mayúsculas, como los de Apple. */
fun projectId(n: Int): String = "00000000-0000-0000-0000-%012d".format(n)

fun project(
    n: Int,
    name: String,
    path: String = "/srv/$name",
    group: String? = null,
    startupCommand: String? = null,
) = Project(
    id = projectId(n),
    name = name,
    group = group,
    path = path,
    startupCommand = startupCommand,
    createdAt = Instant.ofEpochSecond(1_700_000_000),
)

class InMemoryProjectPreferences(initial: ProjectPreferences = ProjectPreferences()) : ProjectPreferencesStore {
    private val state = MutableStateFlow(initial)
    override val preferences: StateFlow<ProjectPreferences> = state

    override fun toggleCollapsed(serverId: String, group: String) =
        state.update { it.copy(collapsed = it.collapsed.toggled(serverId, group)) }

    override fun setStatusFilter(filter: ProjectStatusFilter) = state.update { it.copy(statusFilter = filter) }
}
