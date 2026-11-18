package com.iaportafolio.argos.core.status

/**
 * Lectura del estado de Claude Code en las ventanas tmux del servidor (port de `claudeActivity()`
 * de `ArgosCore/ClaudeStatus/SSHClaudeStatus.swift`). Aparte de
 * [com.iaportafolio.argos.core.SSHServicing] para no obligar a los dobles de prueba a implementarla.
 */
interface ClaudeActivityReading {
    /** Estado de todos los paneles con un solo comando. Sin servidor tmux: vacío. */
    suspend fun claudeActivity(): ClaudeActivitySnapshot
}
