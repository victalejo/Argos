package com.iaportafolio.argos.core.doctor

/**
 * Redacción (lógica pura) del informe «Copiar diagnóstico» (port de `DiagnosticRedactor.swift`).
 *  · SIEMPRE se quitan secretos ([DiagnosticSecretScrubber]).
 *  · Por defecto además se sustituyen los datos personales por marcadores estables dentro de un
 *    mismo informe: servidores (nombre, host, IP) → «servidor-N», usuarios → «usuario-N» (en
 *    `usuario@host`, `/home/<usuario>` y `/Users/<usuario>`), IPs v4/v6 → «servidor-N».
 * Tiene estado (los marcadores se asignan por orden de aparición): usa la misma instancia para
 * todas las secciones de un informe.
 */
class DiagnosticRedactor(
    knownServers: List<KnownServer> = emptyList(),
    val includesPersonalData: Boolean = false,
) {
    /** Un servidor configurado en la app: sus nombres se conocen de antemano. */
    data class KnownServer(val name: String, val host: String, val username: String)

    private val serverAliases = mutableMapOf<String, String>()
    private val userAliases = mutableMapOf<String, String>()
    private var serverCount = 0

    /** Nombres y hosts conocidos, del más largo al más corto. */
    private val knownTerms: List<String>

    init {
        val terms = mutableListOf<String>()
        for (server in knownServers) {
            // Un marcador por servidor: nombre, host y cualquier IP comparten `servidor-N`.
            val alias = serverAlias(server.host.ifEmpty { server.name })
            if (server.name.isNotEmpty()) serverAliases[server.name.lowercase()] = alias
            terms += listOf(server.host, server.name).filter { it.isNotEmpty() }
            val user = server.username.trim(' ', '\t')
            if (user.isNotEmpty()) userAlias(user)
        }
        knownTerms = terms.distinct().sortedByDescending { it.length }
    }

    /** Texto sin secretos y (salvo que se pida lo contrario) sin datos personales. */
    fun redact(text: String): String {
        var result = scrubSecrets(text)
        if (includesPersonalData) return result
        result = redactKnownTerms(result)
        result = redactUserHost(result)
        result = redactHomePaths(result)
        result = redactIPv6(result)
        result = redactIPv4(result)
        return result
    }

    /** Marcador para un nombre de servidor concreto (el del encabezado del informe). */
    fun serverLabel(name: String): String = if (includesPersonalData) scrubSecrets(name) else redact(name)

    private fun serverAlias(term: String): String {
        val key = term.lowercase()
        return serverAliases.getOrPut(key) {
            serverCount++
            "servidor-$serverCount"
        }
    }

    private fun userAlias(user: String): String = userAliases.getOrPut(user) { "usuario-${userAliases.size + 1}" }

    private fun redactKnownTerms(text: String): String {
        var result = text
        for (term in knownTerms) {
            val pattern = Regex(
                "(?<![A-Za-z0-9.\\-])" + Regex.escape(term) + "(?![A-Za-z0-9\\-]|\\.[A-Za-z0-9])",
                setOf(RegexOption.IGNORE_CASE),
            )
            val alias = serverAlias(term)
            result = pattern.replace(result, Regex.escapeReplacement(alias))
        }
        return result
    }

    /** `usuario@host` (también correos): ambos lados pasan a marcadores. */
    private fun redactUserHost(text: String): String = replaceInOrder(USER_HOST, text) { match ->
        val at = match.indexOf('@')
        val user = match.substring(0, at)
        val host = match.substring(at + 1)
        if (user.startsWith("usuario-") && host.startsWith("servidor-")) {
            match // ya redactado
        } else {
            "${userAlias(user)}@${if (host.startsWith("servidor-")) host else serverAlias(host)}"
        }
    }

    private fun redactHomePaths(text: String): String = replaceInOrder(HOME_PATH, text) { match ->
        val parts = match.split("/").filter { it.isNotEmpty() }
        if (parts.size != 2) return@replaceInOrder match
        val user = parts[1]
        if (user.startsWith("usuario-") || user == "Shared") match else "/${parts[0]}/${userAlias(user)}"
    }

    private fun redactIPv4(text: String): String = replaceInOrder(IPV4, text) { match ->
        val octets = match.split(".").mapNotNull(String::toIntOrNull)
        if (octets.size == IPV4_OCTETS && octets.all { it <= MAX_OCTET }) serverAlias(match) else match
    }

    private fun redactIPv6(text: String): String = replaceInOrder(IPV6, text) { match ->
        // Sin `%zona` y validado: «12:30:45» no es una IPv6.
        if (isIPv6(match)) serverAlias(match) else match
    }

    /**
     * Sustituye cada coincidencia por lo que devuelva [transform]. Los marcadores se asignan por
     * orden de aparición (de izquierda a derecha), como en Swift.
     */
    private fun replaceInOrder(pattern: Regex, text: String, transform: (String) -> String): String {
        val replacements = pattern.findAll(text).map { it.range to transform(it.value) }.toList()
        val result = StringBuilder(text)
        for ((range, value) in replacements.asReversed()) result.replace(range.first, range.last + 1, value)
        return result.toString()
    }

    companion object {
        const val KEY_PATH_MARKER = DiagnosticSecretScrubber.KEY_PATH_MARKER
        const val SECRET_MARKER = DiagnosticSecretScrubber.MARKER

        private const val IPV4_OCTETS = 4
        private const val MAX_OCTET = 255
        private const val IPV6_GROUPS = 8
        private const val IPV6_GROUP_DIGITS = 4

        private val USER_HOST = Regex("""(?<![A-Za-z0-9._\-])([A-Za-z0-9._\-]+)@([A-Za-z0-9.\-]+|\[[0-9A-Fa-f:.]+\])""")
        private val HOME_PATH = Regex("""/(?:home|Users)/([^/\s"'<>:]+)""")
        private val IPV4 = Regex("""(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9]|\.\d)""")
        private val IPV6 = Regex("""(?<![0-9A-Za-z:.])[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*(?![0-9A-Za-z:])""")

        /** Quita secretos (siempre, antes que nada y sin depender de ninguna opción). */
        fun scrubSecrets(text: String): String = DiagnosticSecretScrubber.scrub(text)

        /** Lo que `inet_pton(AF_INET6)` acepta: 8 grupos (o menos con un `::`), IPv4 final opcional. */
        fun isIPv6(text: String): Boolean {
            if (text.isEmpty() || text.count { it == ':' } < 2) return false
            val doubleColon = text.indexOf("::")
            if (doubleColon >= 0 && text.indexOf("::", doubleColon + 1) >= 0) return false
            val (head, tail) = if (doubleColon >= 0) {
                text.substring(0, doubleColon) to text.substring(doubleColon + 2)
            } else {
                text to null
            }
            val groups = groupsOf(head, allowIPv4 = tail == null) ?: return false
            val tailGroups = tail?.let { groupsOf(it, allowIPv4 = true) ?: return false } ?: 0
            val total = groups + tailGroups
            return if (doubleColon >= 0) total <= IPV6_GROUPS - 1 else total == IPV6_GROUPS
        }

        /** Grupos (un IPv4 final cuenta 2) de una parte sin `::`; `null` si no es válida. */
        private fun groupsOf(part: String, allowIPv4: Boolean): Int? {
            if (part.isEmpty()) return 0
            val pieces = part.split(":")
            var count = 0
            for ((index, piece) in pieces.withIndex()) {
                val isLast = index == pieces.lastIndex
                when {
                    isLast && allowIPv4 && piece.contains('.') -> {
                        if (!isIPv4(piece)) return null
                        count += 2
                    }
                    piece.length in 1..IPV6_GROUP_DIGITS && piece.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' } -> count++
                    else -> return null
                }
            }
            return count
        }

        private fun isIPv4(text: String): Boolean {
            val octets = text.split(".")
            return octets.size == IPV4_OCTETS && octets.all { octet ->
                octet.length in 1..3 && octet.all(Char::isDigit) && octet.toInt() <= MAX_OCTET
            }
        }
    }
}
