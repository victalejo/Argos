package com.iaportafolio.argos.core.status

/**
 * Partes puras de `ArgosCore/ClaudeStatus/SSHClaudeStatus.swift`: el comando que lee el
 * estado de todos los paneles (un solo `list-panes -a` por sondeo) y la ruta del
 * settings.json donde se instalan los hooks. La lectura/escritura por SSH/SFTP vive en el
 * módulo de red: settings.json puede contener secretos, se escribe con permisos 600 y copia
 * `.argos-backup`.
 */
object ClaudeStatusCommands {

    /**
     * Un `list-panes -a` y, SOLO en los paneles working/waiting/done, un vistazo a su pantalla
     * ([ClaudeScreenSignal]): `2` si el pie dice «esc to interrupt» o hay subagentes en segundo
     * plano («Waiting for 1 background agent to finish»), `1` si hay línea de spinner,
     * `0` si nada, `-` si no se miró. Vale en sh y zsh (por eso `[|]` en los patrones). Salida:
     * `pantalla|estado|pane|ventana|sesión` (ver [ClaudeActivitySnapshot.fromListPanes]).
     */
    const val CLAUDE_ACTIVITY_COMMAND =
        "tmux -u list-panes -a -F '#{${ClaudeHookInstaller.OPTION}}|#{pane_id}|#{window_index}|#{session_name}' 2>/dev/null " +
            "| while IFS= read -r l; do s=\${l%%[|]*}; r=\${l#*[|]}; p=\${r%%[|]*}; c=-; " +
            "if [ \"\$s\" = working ] || [ \"\$s\" = waiting ] || [ \"\$s\" = done ]; then " +
            "t=\$(tmux -u capture-pane -p -t \"\$p\" 2>/dev/null | grep -v '^[[:space:]]*\$'); c=0; " +
            "printf '%s\\n' \"\$t\" | grep -q '… ([0-9]' && c=1; " +
            "printf '%s\\n' \"\$t\" | tail -n 4 | grep -q 'esc to interrupt' && c=2; " +
            "printf '%s\\n' \"\$t\" | grep -q '^[^ ]* Waiting for [0-9]* background' && c=2; " +
            "fi; printf '%s|%s\\n' \"\$c\" \"\$l\"; done"

    /** settings.json de Claude Code, relativo al home del servidor. */
    const val CLAUDE_SETTINGS_RELATIVE_PATH = ".claude/settings.json"

    /**
     * Estado de Claude a partir del resultado de [CLAUDE_ACTIVITY_COMMAND]: sin servidor
     * tmux (código de salida distinto de 0) -> vacío.
     */
    fun parseActivity(exitCode: Int, stdout: String): ClaudeActivitySnapshot =
        if (exitCode == 0) ClaudeActivitySnapshot.fromListPanes(stdout) else ClaudeActivitySnapshot.EMPTY
}
