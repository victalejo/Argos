package com.iaportafolio.argos.ui.files

import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/**
 * Qué enlaces de un Markdown se pueden abrir (port de `SafeLinkPolicy` de Apple): solo
 * `http`, `https` y `mailto`, y siempre tras confirmar la URL completa (el texto del enlace
 * puede engañar). Lógica pura con `java.net.URI` para testearla en la JVM.
 */
object SafeLinkPolicy {
    val ALLOWED_SCHEMES: Set<String> = setOf("http", "https", "mailto")

    fun isAllowed(url: String): Boolean {
        val scheme = try {
            URI(url.trim()).scheme
        } catch (_: URISyntaxException) {
            null
        }
        return scheme?.lowercase(Locale.ROOT) in ALLOWED_SCHEMES
    }
}
