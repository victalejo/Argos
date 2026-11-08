package com.iaportafolio.argos.core.agent

import kotlinx.serialization.json.JsonElement

/**
 * Resumen corto del `input` de una herramienta para mostrarlo junto a su nombre en el
 * transcript y en la tarjeta de permiso (port de `ArgosCore/Agent/AgentToolSummary.swift`).
 */
object AgentToolSummary {

    /** Devuelve un resumen de una línea del input de la herramienta [name]. */
    fun summary(name: String, input: JsonElement): String {
        fun text(key: String) = input.field(key).stringOrNull
        return when (name) {
            "Bash" -> text("command")
            "Read", "Write", "Edit", "MultiEdit", "NotebookEdit" -> text("file_path") ?: text("notebook_path")
            "Glob", "Grep" -> text("pattern")
            "WebFetch" -> text("url")
            "WebSearch" -> text("query")
            else -> text("command") ?: text("file_path") ?: text("pattern") ?: text("description")
        } ?: ""
    }
}
