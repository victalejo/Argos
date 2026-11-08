package com.iaportafolio.argos.ui.importer

import com.iaportafolio.argos.core.keys.ServerTransfer

/**
 * Validación previa de un enlace `argos://add-server?d=…` (escaneado, pegado o recibido por
 * deep link), ANTES de decodificarlo con [ServerTransfer.decode]. Lógica pura, sin Android.
 */
object ImportLink {
    /**
     * Tope de longitud: el enlace real ronda los 300 caracteres; nada legítimo se acerca. Así un
     * texto enorme pegado o recibido de otra app no llega a decodificarse.
     */
    const val MAX_LENGTH = 2_048

    /** Igual que `Intent.ACTION_VIEW` (constante para no depender de Android en tests). */
    const val ACTION_VIEW = "android.intent.action.VIEW"

    private val ADD_SERVER_PREFIX =
        Regex("^${ServerTransfer.SCHEME}://${ServerTransfer.ACTION}(?:[/?#]|$)", RegexOption.IGNORE_CASE)

    fun isTooLong(text: String): Boolean = text.length > MAX_LENGTH

    /** `true` si [text] parece un enlace de importación de Argos (esquema y acción correctos). */
    fun looksLikeAddServer(text: String): Boolean = ADD_SERVER_PREFIX.containsMatchIn(text)

    /**
     * Enlace de un intent de deep link, o `null` si no lo es o no es aceptable: acción distinta
     * de VIEW, otro esquema/acción, demasiado largo o con espacios/caracteres de control. NUNCA
     * importa: solo abre la pantalla de confirmación con el texto.
     */
    fun fromIntent(action: String?, data: String?): String? {
        if (action != ACTION_VIEW || data == null) return null
        if (isTooLong(data) || data.any { it.isWhitespace() || it.isISOControl() }) return null
        return data.takeIf(::looksLikeAddServer)
    }
}
