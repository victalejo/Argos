package com.iaportafolio.argos.core.agent

import java.util.Base64

/**
 * Modo de permisos con el que arrancan los agentes (port de `AgentPermissionPreferences.swift`):
 * el del proyecto si se eligió uno, si no el de Ajustes y, sin nada configurado, [FALLBACK]. Un
 * valor guardado que no se reconoce pregunta cada acción: nunca da más permisos. Se guarda en este
 * dispositivo; nunca en `projects.json`, que comparten los demás clientes. La persistencia es de
 * la plataforma: aquí se recibe como una función de lectura.
 */
object AgentPermissionPreferences {

    val FALLBACK: ClaudeAgentCommand.PermissionMode = ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS

    /** Para un valor guardado que no se reconoce (otra versión de la app, edición externa). */
    val UNRECOGNIZED: ClaudeAgentCommand.PermissionMode = ClaudeAgentCommand.PermissionMode.DEFAULT
    const val GLOBAL_KEY = "agentPermissionMode"

    /** Valor guardado en un proyecto que sigue el ajuste global. */
    const val USE_GLOBAL_CHOICE = ""

    /** La ruta va en base64 porque suele llevar puntos. */
    fun projectKey(serverID: String, workingDirectory: String): String {
        val path = Base64.getEncoder().encodeToString(workingDirectory.toByteArray(Charsets.UTF_8))
        return "$GLOBAL_KEY:$serverID:$path"
    }

    /** Modo global a partir de lo guardado (`null`: nada guardado). */
    fun storedGlobalMode(stored: String?): ClaudeAgentCommand.PermissionMode {
        if (stored == null) return FALLBACK
        return ClaudeAgentCommand.PermissionMode.fromRawValue(stored) ?: UNRECOGNIZED
    }

    /** Elección de un proyecto a partir de lo guardado; `null` si sigue el ajuste global. */
    fun storedProjectChoice(stored: String?): ClaudeAgentCommand.PermissionMode? {
        if (stored == null || stored == USE_GLOBAL_CHOICE) return null
        return ClaudeAgentCommand.PermissionMode.fromRawValue(stored) ?: UNRECOGNIZED
    }

    fun globalMode(read: (String) -> String?): ClaudeAgentCommand.PermissionMode = storedGlobalMode(read(GLOBAL_KEY))

    fun effectiveMode(
        serverID: String,
        workingDirectory: String,
        read: (String) -> String?,
    ): ClaudeAgentCommand.PermissionMode =
        storedProjectChoice(read(projectKey(serverID, workingDirectory))) ?: globalMode(read)
}
