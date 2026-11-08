package com.iaportafolio.argos.core.files

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** Qué visor usar para un archivo (port de `FilePreviewKind`). */
sealed interface FilePreviewKind {
    data object Markdown : FilePreviewKind
    data class Code(val language: String?) : FilePreviewKind
    data object Image : FilePreviewKind
    data object Pdf : FilePreviewKind
    data object Binary : FilePreviewKind
}

/**
 * Elección de visor y límites de tamaño (port de `ArgosCore/Files/FilePreview.swift`).
 * Lógica pura: decide a partir del nombre y de los bytes leídos.
 */
object FilePreview {
    /** Por encima de esto solo se lee el principio del archivo (visor en modo "truncado"). */
    const val MAX_TEXT_BYTES: Long = 2L * 1024 * 1024
    /** Las imágenes se muestran enteras hasta este tamaño. */
    const val MAX_IMAGE_BYTES: Long = 20L * 1024 * 1024
    /** Los PDF se muestran enteros hasta este tamaño (más grandes: solo descargar). */
    const val MAX_PDF_BYTES: Long = 50L * 1024 * 1024

    private const val BINARY_SNIFF_BYTES = 8192
    private const val PDF_SNIFF_BYTES = 1024
    private val PDF_SIGNATURE = "%PDF-".toByteArray(Charsets.US_ASCII)

    private val imageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "ico", "tiff", "avif")
    private val markdownExtensions = setOf("md", "mdx", "markdown")

    private val languages: Map<String, String> = mapOf(
        "swift" to "swift", "ts" to "typescript", "tsx" to "typescript", "js" to "javascript",
        "jsx" to "javascript", "mjs" to "javascript", "cjs" to "javascript", "py" to "python",
        "go" to "go", "rs" to "rust", "rb" to "ruby", "php" to "php", "java" to "java", "kt" to "kotlin",
        "c" to "c", "h" to "c", "cpp" to "cpp", "cs" to "csharp", "dart" to "dart", "json" to "json",
        "yml" to "yaml", "yaml" to "yaml", "toml" to "toml", "sh" to "shell", "bash" to "shell",
        "zsh" to "shell", "sql" to "sql", "html" to "html", "css" to "css", "scss" to "css",
        "vue" to "html", "svelte" to "html", "xml" to "html", "dockerfile" to "shell",
    )

    /** Cuánto leer para previsualizar un archivo según su tipo por nombre. */
    fun readLimit(kind: FilePreviewKind): Long = when (kind) {
        FilePreviewKind.Image -> MAX_IMAGE_BYTES
        FilePreviewKind.Pdf -> MAX_PDF_BYTES
        FilePreviewKind.Markdown, FilePreviewKind.Binary, is FilePreviewKind.Code -> MAX_TEXT_BYTES
    }

    /** Tipo de visor por nombre (para elegir cuánto leer antes de tener los bytes). */
    fun kind(name: String): FilePreviewKind {
        val ext = RemotePath.fileExtension(name)
        return when {
            ext in markdownExtensions -> FilePreviewKind.Markdown
            ext in imageExtensions -> FilePreviewKind.Image
            ext == "pdf" -> FilePreviewKind.Pdf
            name.lowercase().startsWith("dockerfile") -> FilePreviewKind.Code("shell")
            else -> FilePreviewKind.Code(languages[ext])
        }
    }

    /** Tipo definitivo con los bytes: si "parece texto" pero tiene NUL o no es UTF-8, es binario. */
    fun kind(name: String, data: ByteArray): FilePreviewKind {
        val byName = kind(name)
        return when {
            byName == FilePreviewKind.Image -> FilePreviewKind.Image
            byName == FilePreviewKind.Pdf -> if (isPdf(data)) FilePreviewKind.Pdf else FilePreviewKind.Binary
            looksBinary(data) -> FilePreviewKind.Binary
            else -> byName
        }
    }

    /** Firma `%PDF-` al principio (se tolera basura antes, como permiten los lectores). */
    fun isPdf(data: ByteArray): Boolean {
        val head = data.copyOf(minOf(data.size, PDF_SNIFF_BYTES))
        if (head.size < PDF_SIGNATURE.size) return false
        return (0..head.size - PDF_SIGNATURE.size).any { start ->
            PDF_SIGNATURE.indices.all { head[start + it] == PDF_SIGNATURE[it] }
        }
    }

    /** Heurística de binario: un byte NUL en los primeros 8 KB, o UTF-8 inválido. */
    fun looksBinary(data: ByteArray): Boolean {
        val head = data.copyOf(minOf(data.size, BINARY_SNIFF_BYTES))
        if (head.any { it == 0.toByte() }) return true
        // Un corte a mitad de un carácter multibyte al final no lo hace binario.
        return (0..3).filter { head.size >= it }.none { trim -> isValidUtf8(head, head.size - trim) }
    }

    private fun isValidUtf8(bytes: ByteArray, length: Int): Boolean {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes, 0, length))
            true
        } catch (_: CharacterCodingException) {
            false
        }
    }
}
