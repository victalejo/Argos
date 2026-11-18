package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.tmux.TmuxSession
import java.text.Normalizer
import java.util.Locale

/**
 * Búsqueda por texto en la lista de proyectos: cada palabra de la consulta debe aparecer (sin
 * distinguir mayúsculas ni tildes) en el nombre, el grupo o la carpeta del proyecto, o en el nombre
 * de una sesión suelta. Consulta vacía = todo.
 */
object ProjectSearch {

    fun matches(query: String, project: Project): Boolean =
        matchesAll(query, listOfNotNull(project.name, project.group, project.path))

    fun matches(query: String, session: TmuxSession): Boolean = matchesAll(query, listOf(session.name))

    private fun matchesAll(query: String, fields: List<String>): Boolean {
        val words = normalize(query).split(' ').filter { it.isNotEmpty() }
        if (words.isEmpty()) return true
        val haystack = fields.joinToString("\n") { normalize(it) }
        return words.all { it in haystack }
    }

    private val MARKS = Regex("\\p{M}+")
    private val SPACES = Regex("\\s+")

    private fun normalize(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(MARKS, "").lowercase(Locale.ROOT).replace(SPACES, " ").trim()
}
