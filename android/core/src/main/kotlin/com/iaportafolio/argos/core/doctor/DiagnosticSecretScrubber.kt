package com.iaportafolio.argos.core.doctor

/**
 * Eliminación (lógica pura) de SECRETOS en el informe «Copiar diagnóstico» (port de
 * `ArgosCore/Doctor/DiagnosticSecretScrubber.swift`, mismos patrones y casos de prueba). Se aplica
 * SIEMPRE, con o sin datos personales, y ANTES de cualquier recorte por tamaño: bloques de clave
 * privada, credenciales en URL, cabeceras `Authorization`/`Bearer`/`Basic`/`Cookie`, JWT, tokens
 * con prefijo conocido, pares clave/valor con nombres de secreto y rutas de claves privadas. No
 * toca texto normal: «el token caducó», hashes de commit y huellas SHA256 se conservan.
 *
 * Las expresiones llevan `UNICODE_CHARACTER_CLASS` para que `\b`, `\s` y `\d` se comporten como en
 * `NSRegularExpression` (ICU).
 */
object DiagnosticSecretScrubber {

    const val MARKER = "[secreto]"
    const val KEY_PATH_MARKER = "[ruta-de-clave]"
    const val PRIVATE_KEY_MARKER = "[clave-privada]"

    fun scrub(text: String): String {
        var result = text
        result = PEM_BLOCK.replace(result, literal(PRIVATE_KEY_MARKER))
        result = scrubOrphanKeyTails(result)
        result = URL_PASSWORD.replace(result, "$1${literal(MARKER)}@")
        result = URL_TOKEN_AS_USER.replace(result, "$1${literal(MARKER)}@")
        result = AUTHORIZATION_HEADER.replace(result, "$1${literal(MARKER)}")
        result = BEARER.replace(result, literal("Bearer $MARKER"))
        result = BASIC.replace(result) { match ->
            if (hasDigitOrPadding(match.groupValues[1])) "Basic $MARKER" else match.value
        }
        result = JWT.replace(result, literal(MARKER))
        for (pattern in TOKEN_PREFIXES) result = pattern.replace(result, literal(MARKER))
        result = COOKIE.replace(result, "$1${literal(MARKER)}")
        result = COMMAND_LINE_FLAG.replace(result, "$1${literal(MARKER)}")
        result = STRONG_KEY_VALUE.replace(result, "$1${literal(MARKER)}")
        result = AMBIGUOUS_KEY_VALUE.replace(result) { match ->
            if (looksLikeOpaqueValue(match.groupValues[2])) match.groupValues[1] + MARKER else match.value
        }
        result = PATH_CANDIDATE.replace(result) { match ->
            if (looksLikeKeyPath(match.value)) KEY_PATH_MARKER else match.value
        }
        return result
    }

    // MARK: Patrones

    private fun regex(pattern: String): Regex = Regex("(?U)$pattern")

    /** Texto literal en una plantilla de reemplazo (los corchetes no son especiales, `$` y `\` sí). */
    private fun literal(text: String): String = Regex.escapeReplacement(text)

    private val PEM_BLOCK = regex(
        """-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?(?:-----)?[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\z)""",
    )
    private val PEM_END = regex("""-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----""")

    private val URL_PASSWORD = regex("""(?i)([a-z][a-z0-9+.\-]*://[^/\s:@"'<>]*:)[^/\s"'<>]+@""")
    private val URL_TOKEN_AS_USER = regex("""(?i)([a-z][a-z0-9+.\-]*://)[A-Za-z0-9_\-.~%]{20,}@""")

    private val AUTHORIZATION_HEADER = regex(
        """(?i)(authorization["']?\s*[:=]\s*["']?)(?:(?:basic|bearer|token|digest|negotiate)\s+)?(?:\[secreto\]|[^\s"',;}\]]+)""",
    )
    private val BEARER = regex("""\b[Bb]earer\s+[A-Za-z0-9._~+/=\-]{8,}""")
    private val BASIC = regex("""\b[Bb]asic\s+([A-Za-z0-9+/]{8,}={0,2})""")
    private val JWT = regex("""\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}(?:\.[A-Za-z0-9_\-]*)?""")

    /** Tokens con prefijo propio (no dependen de que haya una clave delante). */
    private val TOKEN_PREFIXES = listOf(
        """\bsk-ant-[A-Za-z0-9_\-]{6,}""", // Anthropic (API y OAuth `sk-ant-oat…`)
        """\bsk-[A-Za-z0-9_\-]{20,}""", // `sk-…` genérico (OpenAI y similares)
        """\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}""", // GitHub
        """\bgithub_pat_[A-Za-z0-9_]{16,}""",
        """\bglpat-[A-Za-z0-9_\-]{12,}""", // GitLab
        """\bxox[abprs]-[A-Za-z0-9\-]{8,}""", // Slack
        """\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}\b""", // AWS
        """\bnpm_[A-Za-z0-9]{20,}""",
        """\bAIza[A-Za-z0-9_\-]{30,}""", // Google
        """\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}""", // Stripe
    ).map(::regex)

    private val COOKIE = regex("""(?i)((?:set-)?cookie["']?\s*[:=]\s*)[^\n⏎]+""")
    private val COMMAND_LINE_FLAG = regex(
        """(?i)(--(?:[a-z0-9]+-)*(?:token|password|passwd|passphrase|secret|api[_-]?key)(?:=|\s+))(?:\[secreto\]|"[^"]*"|'[^']*'|[^\s"']+)""",
    )

    private const val STRONG_WORDS =
        "token|password|passwd|passphrase|secret|api[_-]?key|credentials?|private[_-]?key|session[_-]?(?:id|key|token)|sessionid|authorization"

    /** `clave = valor`, `"clave": "valor"`, `export CLAVE_TOKEN=valor`. */
    private val STRONG_KEY_VALUE = regex(
        """(?i)(["']?[A-Za-z0-9_.\-]*(?:""" + STRONG_WORDS +
            """)[A-Za-z0-9_\-]*["']?\s*[=:]\s*)(?:\[secreto\]|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;&"'}\]]+)""",
    )

    /** Claves cortas y ambiguas: solo se oculta un valor con pinta de credencial opaca. */
    private val AMBIGUOUS_KEY_VALUE = regex("""(?i)(["']?\b(?:auth|session)["']?\s*[=:]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;"'}\]]+)""")

    private val PATH_CANDIDATE = regex("""(?:~|/)[^\s"'<>]*""")

    // MARK: Reglas con código

    private const val OPAQUE_MIN = 10
    private const val OPAQUE_LONG = 16
    private const val KEY_BODY_WORD = 16
    private const val OPAQUE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=._~-%"

    private fun hasDigitOrPadding(text: String): Boolean = text.contains('=') || text.any(Character::isDigit)

    /** Valor sin espacios de 16+ caracteres, o de 10+ con algún dígito, en alfabeto de token. */
    private fun looksLikeOpaqueValue(raw: String): Boolean {
        val value = raw.trim('"', '\'')
        if (value.length < OPAQUE_MIN || value == MARKER) return false
        if (!value.all { it in OPAQUE_ALPHABET }) return false
        return value.length >= OPAQUE_LONG || value.any(Char::isDigit)
    }

    fun looksLikeKeyPath(path: String): Boolean {
        val lower = path.lowercase()
        if (lower.contains("/.ssh/") || lower.startsWith("~/.ssh")) return true
        val name = lower.split("/").lastOrNull { it.isNotEmpty() } ?: lower
        if (listOf("id_rsa", "id_ed25519", "id_ecdsa", "id_dsa").any(name::startsWith)) return true
        return listOf(".pem", ".key", ".ppk").any(name::endsWith)
    }

    /**
     * Cuerpo de una clave privada cuya cabecera se perdió (registro cortado): se retira el pie
     * `-----END … PRIVATE KEY-----` y las palabras base64 largas que lo preceden, hacia atrás por
     * palabras (sin expresiones con retroceso: el texto puede ser grande).
     */
    private fun scrubOrphanKeyTails(text: String): String {
        val matches = PEM_END.findAll(text).toList()
        if (matches.isEmpty()) return text
        val result = StringBuilder(text)
        for (match in matches.asReversed()) {
            val footerStart = match.range.first
            var start = footerStart
            var cursor = footerStart
            var sawLongWord = false
            var words = 0
            while (cursor > 0) {
                var wordEnd = cursor
                while (wordEnd > 0 && isSeparator(result[wordEnd - 1])) wordEnd--
                var wordStart = wordEnd
                while (wordStart > 0 && isBase64(result[wordStart - 1])) wordStart--
                val length = wordEnd - wordStart
                if (length >= KEY_BODY_WORD) {
                    sawLongWord = true
                } else if (!(words == 0 && length >= 2)) {
                    break // solo la última línea del cuerpo puede ser corta
                }
                start = wordStart
                cursor = wordStart
                words++
            }
            // Sin ninguna palabra larga no era un cuerpo de clave: solo se retira el pie.
            if (!sawLongWord) start = footerStart
            result.replace(start, match.range.last + 1, PRIVATE_KEY_MARKER)
        }
        return result.toString()
    }

    private fun isSeparator(character: Char): Boolean = character.isWhitespace() || character == '⏎'

    private fun isBase64(character: Char): Boolean =
        character in 'A'..'Z' || character in 'a'..'z' || character in '0'..'9' || character in "+/="
}
