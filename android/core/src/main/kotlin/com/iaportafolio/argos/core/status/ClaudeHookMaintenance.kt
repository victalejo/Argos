package com.iaportafolio.argos.core.status

/**
 * Mantenimiento de los hooks del indicador de Claude (port de `upgradeClaudeHooksIfOutdated` de
 * `ArgosCore/ClaudeStatus/SSHClaudeStatus.swift`). Aparte de [com.iaportafolio.argos.core.SSHServicing]
 * para no obligar a los dobles de prueba a implementarlo.
 */
interface ClaudeHookMaintenance {
    /**
     * Si el indicador ya se activó con una versión anterior de los hooks, los actualiza sin
     * preguntar (el usuario ya dio su permiso). Devuelve si escribió `~/.claude/settings.json`.
     */
    suspend fun upgradeClaudeHooksIfOutdated(): Boolean
}
