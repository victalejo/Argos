package com.iaportafolio.argos.core.agent

import java.net.URI

/**
 * Interpreta la salida de `claude auth login --claudeai` (corre en un PTY del servidor)
 * para guiar el login con UI nativa (port de `ArgosCore/Agent/ClaudeLoginOutput.swift`):
 * detecta el enlace de autorización y el momento en que el CLI pide el código.
 *
 * Formato real observado (CLI 2026):
 * ```
 * Opening browser to sign in…
 * If the browser didn't open, visit: ESC]8;;<URL>BEL<URL>ESC]8;;BEL
 * Paste code here if prompted >
 * ```
 * Lógica tolerante: si el texto cambia, la UI cae al terminal embebido.
 */
data class ClaudeLoginOutput(
    /** Enlace de autorización OAuth (solo de dominios de Anthropic). */
    val authorizationURL: URI?,
    /** El CLI ya espera que se pegue el código. */
    val isAwaitingCode: Boolean,
) {
    companion object {

        /** Solo se abren enlaces de Anthropic (la salida viene del servidor: no confiar). */
        val trustedHosts: List<String> = listOf("claude.com", "claude.ai", "anthropic.com")

        private const val ESC = 0x1B
        private const val BEL = 0x07
        private const val TRIMMED = "<>\"'()[]"

        /** Analiza TODA la salida acumulada hasta ahora. */
        fun parse(raw: String): ClaudeLoginOutput {
            val text = stripEscapes(raw)
            return ClaudeLoginOutput(
                authorizationURL = firstAuthorizationURL(text),
                isAwaitingCode = text.contains("paste code", ignoreCase = true),
            )
        }

        /**
         * Quita secuencias de escape de terminal: OSC (`ESC ] … BEL` o `ESC ] … ESC \`),
         * CSI (`ESC [ … letra`) y retornos de carro, dejando el texto visible.
         */
        fun stripEscapes(raw: String): String {
            val scalars = raw.codePoints().toArray()
            val result = StringBuilder()
            var i = 0
            fun next(): Int? = if (i < scalars.size) scalars[i++] else null
            while (true) {
                val scalar = next() ?: break
                when (scalar) {
                    ESC -> when (next()) {
                        ']'.code -> skipOsc(::next)
                        '['.code -> skipCsi(::next)
                        else -> Unit // ESC + otro carácter (o fin): ambos se descartan
                    }
                    '\r'.code -> Unit
                    else -> result.appendCodePoint(scalar)
                }
            }
            return result.toString()
        }

        /** OSC: hasta BEL o `ESC \` (el texto visible ya repite la URL del enlace). */
        private fun skipOsc(next: () -> Int?) {
            while (true) {
                when (next() ?: return) {
                    BEL -> return
                    ESC -> {
                        next()
                        return
                    }
                }
            }
        }

        /** CSI: hasta el byte final (`@`…`~`), que también se consume. */
        private fun skipCsi(next: () -> Int?) {
            while (true) {
                val c = next() ?: return
                if (c in '@'.code..'~'.code) return
            }
        }

        private fun firstAuthorizationURL(text: String): URI? = tokens(text).firstNotNullOfOrNull { token ->
            val candidate = token.trim { it in TRIMMED }
            if (!candidate.startsWith("https://") || !candidate.contains("oauth")) return@firstNotNullOfOrNull null
            val uri = runCatching { URI(candidate) }.getOrNull() ?: return@firstNotNullOfOrNull null
            val host = uri.host?.lowercase() ?: return@firstNotNullOfOrNull null
            uri.takeIf { trustedHosts.any { host == it || host.endsWith(".$it") } }
        }

        private fun tokens(text: String): List<String> {
            val result = mutableListOf<String>()
            val current = StringBuilder()
            for (c in text) {
                if (SwiftText.isWhitespaceOrNewline(c)) {
                    if (current.isNotEmpty()) result += current.toString()
                    current.clear()
                } else {
                    current.append(c)
                }
            }
            if (current.isNotEmpty()) result += current.toString()
            return result
        }
    }
}
