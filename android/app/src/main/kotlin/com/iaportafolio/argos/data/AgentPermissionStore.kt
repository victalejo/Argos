package com.iaportafolio.argos.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.iaportafolio.argos.core.agent.AgentPermissionPreferences
import com.iaportafolio.argos.core.agent.ClaudeAgentCommand.PermissionMode
import com.iaportafolio.argos.core.agent.PersistentAgentHibernation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Dónde se guardan los modos: clave → valor, sin Android para poder probar el almacén en la JVM. */
interface AgentPermissionBackend {
    fun readAll(): Map<String, String>

    /** `null` borra la clave. */
    fun write(key: String, value: String?)
}

/** Lo elegido para un proyecto. [choice] nulo = sigue el ajuste global. */
data class AgentPermissionSelection(val choice: PermissionMode?, val global: PermissionMode) {
    val effective: PermissionMode get() = choice ?: global
}

/**
 * Ajustes de los agentes en ESTE dispositivo: modos de permisos (claves de
 * `AgentPermissionPreferences`) y horas de inactividad antes de ponerlos en reposo (la clave de
 * `AgentHibernationPreferences` de Apple). Nunca en `projects.json`, que comparten los demás.
 */
class AgentPermissionStore(private val backend: AgentPermissionBackend) {
    private val state = MutableStateFlow(backend.readAll())

    /** Cambia con cada ajuste: las pantallas abiertas lo observan. */
    val values: StateFlow<Map<String, String>> = state.asStateFlow()

    fun globalMode(): PermissionMode = AgentPermissionPreferences.globalMode(state.value::get)

    /** El modo con el que arrancaría AHORA un agente nuevo de ese proyecto. */
    fun effectiveMode(serverId: String, workingDirectory: String): PermissionMode =
        AgentPermissionPreferences.effectiveMode(serverId, workingDirectory, state.value::get)

    fun selection(serverId: String, workingDirectory: String): AgentPermissionSelection = AgentPermissionSelection(
        choice = AgentPermissionPreferences.storedProjectChoice(
            state.value[AgentPermissionPreferences.projectKey(serverId, workingDirectory)],
        ),
        global = globalMode(),
    )

    fun setGlobalMode(mode: PermissionMode) = put(AgentPermissionPreferences.GLOBAL_KEY, mode.rawValue)

    /** [mode] nulo vuelve al ajuste global. */
    fun setProjectChoice(serverId: String, workingDirectory: String, mode: PermissionMode?) =
        put(AgentPermissionPreferences.projectKey(serverId, workingDirectory), mode?.rawValue)

    /** Horas sin actividad antes de hibernar (0 = nunca); un valor no válido vuelve al de serie. */
    fun hibernationHours(): Int = PersistentAgentHibernation.sanitizedHours(state.value[HIBERNATION_KEY]?.toIntOrNull())

    fun hibernation(): PersistentAgentHibernation = PersistentAgentHibernation.ofHours(hibernationHours())

    fun setHibernationHours(hours: Int) = put(HIBERNATION_KEY, PersistentAgentHibernation.sanitizedHours(hours).toString())

    private fun put(key: String, value: String?) {
        state.update { if (value == null) it - key else it + (key to value) }
        backend.write(key, value)
    }
}

/** Misma clave que `AgentHibernationPreferences.key` de Apple. */
const val HIBERNATION_KEY = "agent.hibernation.idleHours"

/** [AgentPermissionBackend] sobre `SharedPreferences`, excluido de las copias como todo lo local. */
class SharedPreferencesAgentPermissions(context: Context) : AgentPermissionBackend {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun readAll(): Map<String, String> = buildMap {
        prefs.all.forEach { (key, value) -> if (value is String) put(key, value) }
    }

    override fun write(key: String, value: String?) = prefs.edit {
        if (value == null) remove(key) else putString(key, value)
    }

    private companion object {
        const val FILE = "agent_permissions"
    }
}
