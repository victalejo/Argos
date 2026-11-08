package com.iaportafolio.argos.core.tmux

import java.util.Locale

/**
 * Catálogo de agentes de terminal que se pueden lanzar en una ventana tmux (Claude Code,
 * Codex, Grok). Port de la lógica de `ArgosCore/Tabs/CodingAgent.swift`: nombre, binario,
 * atajo del menú, detección por el proceso en primer plano y el script que averigua cuáles
 * están instalados en el servidor.
 */
enum class CodingAgent(
    /** Valor persistido / identidad (igual al `rawValue` de Apple). */
    val rawValue: String,
    /**
     * Nombre visible (pestaña, menú). También es el nombre que se le pone a la ventana tmux al
     * lanzarlo, lo que permite reconocerla aunque el proceso cambie de nombre.
     */
    val displayName: String,
    /** Tecla del atajo en el menú «+» (1, 2, 3…). */
    val menuKey: Char,
) {
    CLAUDE("claude", "Claude Code", '1'),
    CODEX("codex", "Codex", '2'),
    GROK("grok", "Grok", '3'),
    ;

    val id: String get() = rawValue

    /** Ejecutable en el servidor. */
    val binary: String get() = rawValue

    companion object {
        /** Marca que precede a cada agente encontrado en la salida del script (filtra el MOTD). */
        const val INSTALLED_MARKER = "argos-agent:"

        /**
         * Directorios habituales donde un agente puede estar fuera del PATH de un shell de login
         * (instalador nativo, npm global, bun, Homebrew…).
         */
        val FALLBACK_DIRECTORIES: List<String> = listOf(
            "\$HOME/.local/bin", "\$HOME/.claude/local", "\$HOME/.npm-global/bin",
            "\$HOME/.bun/bin", "\$HOME/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin",
        )

        fun fromRawValue(rawValue: String): CodingAgent? = entries.firstOrNull { it.rawValue == rawValue }

        /**
         * Reconoce el agente de una ventana: por el proceso en primer plano
         * (`pane_current_command`) o, si no coincide, por el nombre que Argos le puso a la ventana
         * al lanzarlo (p. ej. si el agente corre como `node`). El nombre no cuenta si la ventana ya
         * volvió a su shell: el agente salió.
         */
        fun detect(command: String?, windowName: String): CodingAgent? {
            if (command != null) {
                val normalized = command.trim { it == ' ' || it == '\t' }.lowercase(Locale.ROOT)
                entries.firstOrNull { it.binary == normalized }?.let { return it }
                if (WindowTabs.isIdleShell(normalized)) return null
            }
            return entries.firstOrNull { it.displayName == windowName }
        }

        /**
         * Script de shell que imprime `argos-agent:<binario>` por cada agente instalado. Prueba
         * el PATH del shell de login y, después, los directorios habituales y las versiones de
         * Node de nvm. Solo usa constantes (sin entrada del usuario): nada que entrecomillar.
         * Idéntico byte a byte al de Apple.
         */
        val installedAgentsScript: String by lazy {
            val binaries = entries.joinToString(" ") { it.binary }
            val directories = FALLBACK_DIRECTORIES.joinToString(" ") { "\"$it\"" }
            listOf(
                "found=\$(\"\${SHELL:-sh}\" -lc 'for b in $binaries; do command -v \"\$b\" >/dev/null 2>&1 " +
                    "&& echo \"\$b\"; done' 2>/dev/null)",
                "for b in $binaries; do",
                "  hit=\"\"",
                "  case \" \$(echo \$found) \" in *\" \$b \"*) hit=1;; esac",
                "  if [ -z \"\$hit\" ]; then",
                "    for d in $directories \"\$HOME\"/.nvm/versions/node/*/bin; do",
                "      [ -x \"\$d/\$b\" ] && { hit=1; break; }",
                "    done",
                "  fi",
                "  [ -n \"\$hit\" ] && echo \"$INSTALLED_MARKER\$b\"",
                "done",
                "exit 0",
            ).joinToString("\n")
        }

        /**
         * Interpreta la salida de [installedAgentsScript]: solo cuentan las líneas con la marca y
         * un binario conocido.
         */
        fun parseInstalled(output: String): Set<CodingAgent> = output.lineSequence()
            .map { it.trim { c -> c == ' ' || c == '\t' } }
            .filter { it.startsWith(INSTALLED_MARKER) }
            .mapNotNull { fromRawValue(it.removePrefix(INSTALLED_MARKER)) }
            .toSet()
    }
}
