package com.iaportafolio.argos.core.tmux

import java.text.Collator
import java.util.Locale

/** Un grupo de sesiones que comparten prefijo (port de `SessionGroup`). */
data class SessionGroup(
    /** Nombre del grupo ("magic-agents", "General", …). Único en la lista. */
    val name: String,
    /** Sesiones del grupo, ya ordenadas por su nombre corto. */
    val sessions: List<TmuxSession>,
) {
    val id: String get() = name
}

/**
 * Agrupamiento de sesiones por convención de nombres, SIN estado extra
 * (port de `ArgosCore/SessionGroup.swift`).
 *
 * El prefijo anterior al primer '/' define el grupo: "magic-agents/backend" → "magic-agents".
 * Las sesiones sin '/' caen en "General". El nombre COMPLETO sigue siendo el target real.
 */
object SessionGrouping {

    /** Separador de grupo dentro del nombre de la sesión. */
    const val SEPARATOR: Char = '/'

    /** Grupo al que van las sesiones sin separador. */
    const val UNGROUPED_NAME = "General"

    /** Resultado de [split]: grupo y nombre corto para mostrar. */
    data class Parts(val group: String, val short: String)

    /**
     * Comparación sin distinguir mayúsculas (sí acentos), como `localizedCaseInsensitiveCompare`.
     * Se crea por llamada porque `Collator` no es seguro entre hilos.
     */
    private fun caseInsensitiveCollator(): Collator =
        Collator.getInstance(Locale.getDefault()).apply { strength = Collator.SECONDARY }

    /**
     * Descompone un nombre completo en grupo y nombre corto:
     * - "magic-agents/backend" → ("magic-agents", "backend")
     * - "main" → ("General", "main")
     * - "/foo" (prefijo vacío) → ("General", "/foo")
     * - "foo/" (sufijo vacío) → ("foo", "foo/")
     */
    fun split(fullName: String): Parts {
        val index = fullName.indexOf(SEPARATOR)
        if (index < 0) return Parts(UNGROUPED_NAME, fullName)
        val prefix = fullName.substring(0, index)
        val suffix = fullName.substring(index + 1)
        if (prefix.isEmpty()) return Parts(UNGROUPED_NAME, fullName)
        // Sin nada tras el '/', se muestra el nombre completo para no dejar la fila sin etiqueta.
        return Parts(prefix, suffix.ifEmpty { fullName })
    }

    fun groupName(fullName: String): String = split(fullName).group

    fun shortName(fullName: String): String = split(fullName).short

    /**
     * Agrupa y ordena: grupos alfabéticamente (sin distinguir mayúsculas) con "General" SIEMPRE
     * al final; dentro de cada grupo, por nombre corto.
     */
    fun groups(sessions: List<TmuxSession>): List<SessionGroup> {
        val collator = caseInsensitiveCollator()
        val buckets = sessions.groupBy { groupName(it.name) }
        val groupOrder = compareBy<String> { it == UNGROUPED_NAME }.then { a, b -> collator.compare(a, b) }
        return buckets.keys.sortedWith(groupOrder).map { name ->
            val sorted = buckets.getValue(name).sortedWith { a, b ->
                collator.compare(shortName(a.name), shortName(b.name))
            }
            SessionGroup(name, sorted)
        }
    }
}
