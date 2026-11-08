package com.iaportafolio.argos.core.status

/**
 * Partes puras de `ArgosCore/ClaudeStatus/SSHClaudeStatus.swift`: el comando que lee el
 * estado de todos los paneles (un solo `list-panes -a` por sondeo) y la ruta del
 * settings.json donde se instalan los hooks. La lectura/escritura por SSH/SFTP vive en el
 * módulo de red: settings.json puede contener secretos, se escribe con permisos 600 y copia
 * `.argos-backup`.
 */
object ClaudeStatusCommands {

    /** Salida: `estado|ventana|sesión` por panel (ver [ClaudeActivitySnapshot.fromListPanes]). */
    const val CLAUDE_ACTIVITY_COMMAND =
        "tmux list-panes -a -F '#{${ClaudeHookInstaller.OPTION}}|#{window_index}|#{session_name}' 2>/dev/null"

    /** settings.json de Claude Code, relativo al home del servidor. */
    const val CLAUDE_SETTINGS_RELATIVE_PATH = ".claude/settings.json"

    /**
     * Estado de Claude a partir del resultado de [CLAUDE_ACTIVITY_COMMAND]: sin servidor
     * tmux (código de salida distinto de 0) -> vacío.
     */
    fun parseActivity(exitCode: Int, stdout: String): ClaudeActivitySnapshot =
        if (exitCode == 0) ClaudeActivitySnapshot.fromListPanes(stdout) else ClaudeActivitySnapshot.EMPTY
}
