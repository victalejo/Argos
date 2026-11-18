package com.iaportafolio.argos.core.files

import java.net.URI
import java.net.URISyntaxException

/**
 * Reglas del visor HTML para páginas del servidor (contenido NO confiable), port de
 * `ArgosCore/Files/HTMLPreviewPolicy.swift`. Lógica pura; la aplica el visor (WebView).
 *
 * Por defecto la página se ve "aislada": sin JavaScript y sin ninguna petición de red (ni
 * imágenes, ni CSS, ni fuentes remotas), para no revelar la IP ni permitir rastreo, igual que el
 * visor de Markdown. El usuario puede permitir JavaScript y recursos externos para esa página. En
 * ningún caso la página navega por su cuenta: los enlaces que pulsa el usuario se abren fuera
 * (solo http/https/mailto, tras confirmar).
 */
object HtmlPreviewPolicy {

    /** Qué hacer con una navegación dentro del visor. */
    sealed interface Decision {
        data object Allow : Decision
        data object Cancel : Decision

        /** Abrir fuera del visor (navegador o correo), tras confirmar con el usuario. */
        data class OpenExternally(val url: String) : Decision
    }

    val EXTERNAL_SCHEMES: Set<String> = setOf("http", "https", "mailto")

    /** Esquemas de contenido incrustado en la propia página (sin red): siempre se cargan. */
    val EMBEDDED_SCHEMES: Set<String> = setOf("about", "data", "blob")

    private val IFRAME_SCHEMES = setOf("http", "https", "data")

    /** Página que se muestra si no se pudo activar el bloqueo (se falla cerrado). */
    const val BLOCKER_UNAVAILABLE_PAGE: String =
        "<html><body style=\"font: 14px -apple-system, sans-serif; color: #666; padding: 24px\">\n" +
            "No se pudo activar el bloqueo de contenido externo, así que la página no se muestra.\n" +
            "Usa la vista «Fuente» o permite el contenido externo.\n" +
            "</body></html>"

    /**
     * Qué hacer con una navegación dentro del visor.
     *
     * @param isUserLink el usuario pulsó un enlace.
     * @param isMainFrame navega el documento principal (no un iframe).
     */
    fun decide(url: String?, isUserLink: Boolean, isMainFrame: Boolean, allowsRemoteContent: Boolean): Decision {
        val target = url ?: return Decision.Cancel
        val scheme = scheme(target) ?: return Decision.Cancel
        return when {
            // Carga inicial (about:blank), anclas `#…` e iframes srcdoc.
            scheme == "about" -> Decision.Allow
            isUserLink -> if (scheme in EXTERNAL_SCHEMES) Decision.OpenExternally(target) else Decision.Cancel
            // Iframes (vídeos, mapas…) solo si el usuario permitió el contenido externo.
            !isMainFrame && allowsRemoteContent && scheme in IFRAME_SCHEMES -> Decision.Allow
            // Redirecciones, formularios, `location = …`, meta refresh: nunca.
            else -> Decision.Cancel
        }
    }

    /**
     * ¿Se puede cargar este recurso (imagen, CSS, script, fuente)? Equivale a la lista de reglas
     * de contenido de Apple (`blockRemoteRules`): sin permiso, todo bloqueado salvo `about:`,
     * `data:` y `blob:`.
     */
    fun allowsResource(url: String?, allowsRemoteContent: Boolean): Boolean {
        val scheme = url?.let(::scheme) ?: return false
        return scheme in EMBEDDED_SCHEMES || allowsRemoteContent
    }

    /** Esquema en minúsculas, o `null` si la URL no es válida o no tiene. */
    private fun scheme(url: String): String? {
        if (url.isEmpty()) return null
        return try {
            URI(url).scheme?.lowercase()
        } catch (_: URISyntaxException) {
            null
        }
    }
}
