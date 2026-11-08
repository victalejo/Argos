package com.iaportafolio.argos.core.projects

/**
 * Constantes de las preferencias globales de proyectos (la parte pura de
 * `ArgosCore/Projects/ProjectSettings.swift`; la persistencia es de cada plataforma). Cada
 * proyecto puede sobrescribir el comando de arranque; si no, usa el predeterminado.
 */
object ProjectDefaults {

    /**
     * `cc` es el alias habitual de Claude Code; `--continue` retoma la última conversación de
     * la carpeta (y empieza una nueva si no hay).
     */
    const val FACTORY_STARTUP_COMMAND = "cc --continue"

    /** Clave con la que Apple guarda la preferencia (por coherencia entre plataformas). */
    const val DEFAULTS_KEY = "projects.defaultStartupCommand"

    /** Atajo ofrecido en Ajustes y en el formulario del proyecto. */
    data class Preset(val label: String, val command: String)

    val PRESETS: List<Preset> = listOf(
        Preset("Claude Code, continuar conversación", "cc --continue"),
        Preset("Claude Code, conversación nueva", "cc"),
        Preset("claude --continue (sin alias)", "claude --continue"),
        Preset("No lanzar nada", ""),
    )
}
