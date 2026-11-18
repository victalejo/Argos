package com.iaportafolio.argos.ui.share

/**
 * Lo que llega por «Compartir» (`ACTION_SEND` / `ACTION_SEND_MULTIPLE`). Otra app puede mandar
 * cualquier cosa: solo se aceptan `content://` (nada de `file://`, que podría apuntar a los archivos
 * privados de Argos) y como mucho [MAX_ITEMS].
 */
object ShareIntent {
    const val ACTION_SEND = "android.intent.action.SEND"
    const val ACTION_SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"
    const val MAX_ITEMS = 10

    private const val CONTENT_SCHEME = "content://"

    fun isShare(action: String?): Boolean = action == ACTION_SEND || action == ACTION_SEND_MULTIPLE

    /** `content://` válidos de [streams] (vacío = nada que subir). */
    fun accepted(action: String?, streams: List<String?>): List<String> {
        if (!isShare(action)) return emptyList()
        return streams.filterNotNull()
            .filter { it.regionMatches(0, CONTENT_SCHEME, 0, CONTENT_SCHEME.length, ignoreCase = true) && it.length > CONTENT_SCHEME.length }
            .distinct()
            .take(MAX_ITEMS)
    }
}
