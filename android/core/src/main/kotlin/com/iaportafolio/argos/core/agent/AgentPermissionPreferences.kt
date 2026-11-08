package com.iaportafolio.argos.core.agent

import java.util.Base64

/**
 * Modo de permisos con el que arrancan los agentes (port de `AgentPermissionPreferences.swift`):
 * el del proyecto si se eligió uno, si no el de Ajustes y, sin nada configurado, [FALLBACK]. Se
 * guarda en este dispositivo; nunca en `projects.json`, que comparten los demás clientes. La
 * persistencia es de la plataforma: aquí se recibe como una función de lectura.
 */
object AgentPermissionPreferences {

    val FALLBACK: ClaudeAgentCommand.PermissionMode = ClaudeAgentCommand.PermissionMode.BYPASS_PERMISSIONS
    const val GLOBAL_KEY = "agentPermissionMode"

    /** Valor guardado en un proyecto que sigue el ajuste global. */
    const val USE_GLOBAL_CHOICE = ""

    /** La ruta va en base64 porque suele llevar puntos. */
    fun projectKey(serverID: String, workingDirectory: String): String {
        val path = Base64.getEncoder().encodeToString(workingDirectory.toByteArray(Charsets.UTF_8))
        return "$GLOBAL_KEY:$serverID:$path"
    }

    fun globalMode(read: (String) -> String?): ClaudeAgentCommand.PermissionMode =
        ClaudeAgentCommand.PermissionMode.fromRawValue(read(GLOBAL_KEY)) ?: FALLBACK

    fun effectiveMode(
        serverID: String,
        workingDirectory: String,
        read: (String) -> String?,
    ): ClaudeAgentCommand.PermissionMode =
        ClaudeAgentCommand.PermissionMode.fromRawValue(read(projectKey(serverID, workingDirectory))) ?: globalMode(read)
}
