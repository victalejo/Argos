package com.iaportafolio.argos.ssh

/**
 * Rutas remotas de las subidas (port de los estáticos privados de `SSHFileTransfer.swift`).
 * Se usa `/tmp` por ser siempre escribible y de ruta absoluta conocida (no depende de `$HOME`).
 */
internal object UploadPaths {
    private const val ALLOWED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    private const val FALLBACK_NAME = "archivo"

    /** `/tmp/argos-pasted-<ms>.<ext>` (datos pegados). */
    fun pasted(fileExtension: String, stamp: Long): String = "/tmp/argos-pasted-$stamp.$fileExtension"

    /** `/tmp/argos-<ms>-<nombre saneado>` (archivo soltado). */
    fun dropped(originalName: String, stamp: Long): String = "/tmp/argos-$stamp-${sanitize(originalName)}"

    /**
     * Deja solo `[A-Za-z0-9._-]` del último componente de la ruta; el resto (por escalar
     * Unicode, como Swift) pasa a `_`. Vacío → `archivo`.
     */
    fun sanitize(name: String): String {
        val result = buildString {
            lastPathComponent(name).codePoints().forEach { point ->
                append(if (point < 0x80 && ALLOWED.indexOf(point.toChar()) >= 0) point.toChar() else '_')
            }
        }
        return result.ifEmpty { FALLBACK_NAME }
    }

    /** Como `NSString.lastPathComponent`: ignora las barras finales; solo barras → "/". */
    private fun lastPathComponent(path: String): String {
        val trimmed = path.trimEnd('/')
        return when {
            trimmed.isEmpty() && path.isNotEmpty() -> "/"
            else -> trimmed.substringAfterLast('/')
        }
    }
}
