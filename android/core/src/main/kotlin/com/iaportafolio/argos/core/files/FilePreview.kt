package com.iaportafolio.argos.core.files

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** Qué visor usar para un archivo (port de `FilePreviewKind`). */
sealed interface FilePreviewKind {
    data object Markdown : FilePreviewKind

    /** Página HTML: se renderiza (con su fuente disponible). Ver [HtmlPreviewPolicy]. */
    data object Html : FilePreviewKind
    data class Code(val language: String?) : FilePreviewKind
    data object Image : FilePreviewKind
    data object Pdf : FilePreviewKind

    /** Hoja de cálculo (Excel, Numbers): la abre un visor del sistema con el archivo completo. */
    data object Spreadsheet : FilePreviewKind
    data object Binary : FilePreviewKind
}

/**
 * Elección de visor, límites de tamaño y decodificación del texto (port de
 * `ArgosCore/Files/FilePreview.swift`). Lógica pura: decide a partir del nombre y de los bytes
 * leídos, y decodifica el texto (UTF-8, UTF-16 con BOM o Windows-1252/Latin-1).
 */
object FilePreview {
    /** Por encima de esto solo se lee el principio del archivo (visor en modo "truncado"). */
    const val MAX_TEXT_BYTES: Long = 2L * 1024 * 1024
    /** Las imágenes se muestran enteras hasta este tamaño. */
    const val MAX_IMAGE_BYTES: Long = 20L * 1024 * 1024
    /** Los PDF se muestran enteros hasta este tamaño (más grandes: solo descargar). */
    const val MAX_PDF_BYTES: Long = 50L * 1024 * 1024
    /** Las hojas de cálculo se muestran enteras hasta este tamaño (el visor necesita el archivo completo). */
    const val MAX_SPREADSHEET_BYTES: Long = 30L * 1024 * 1024

    private const val SNIFF_BYTES = 8192
    private const val PDF_SNIFF_BYTES = 1024
    private val PDF_SIGNATURE = "%PDF-".toByteArray(Charsets.US_ASCII)
    private val ZIP_SIGNATURE = bytes(0x50, 0x4B, 0x03, 0x04)
    private val OLE2_SIGNATURE = bytes(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
    private val WINDOWS_1252 = charset("windows-1252")

    /** Controles permitidos en texto: tab, saltos de línea, form feed y ESC. */
    private val ALLOWED_CONTROLS = setOf(0x09, 0x0A, 0x0C, 0x0D, 0x1B)

    /** Más de 1 control de cada 50 caracteres (2 %) = binario. */
    private const val CONTROL_RATIO = 50

    private val imageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "ico", "tiff", "avif")
    private val markdownExtensions = setOf("md", "mdx", "markdown")
    private val htmlExtensions = setOf("html", "htm", "xhtml")
    private val spreadsheetExtensions = setOf("xlsx", "xlsm", "xls", "numbers")

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
        FilePreviewKind.Spreadsheet -> MAX_SPREADSHEET_BYTES
        FilePreviewKind.Markdown, FilePreviewKind.Html, FilePreviewKind.Binary, is FilePreviewKind.Code -> MAX_TEXT_BYTES
    }

    /** Tipo de visor por nombre (para elegir cuánto leer antes de tener los bytes). */
    fun kind(name: String): FilePreviewKind {
        val ext = RemotePath.fileExtension(name)
        return when {
            ext in markdownExtensions -> FilePreviewKind.Markdown
            ext in htmlExtensions -> FilePreviewKind.Html
            ext in imageExtensions -> FilePreviewKind.Image
            ext == "pdf" -> FilePreviewKind.Pdf
            ext in spreadsheetExtensions -> FilePreviewKind.Spreadsheet
            name.lowercase().startsWith("dockerfile") -> FilePreviewKind.Code("shell")
            else -> FilePreviewKind.Code(languages[ext])
        }
    }

    /** Tipo definitivo con los bytes: si "parece texto" pero no se puede decodificar ([decodeText]), es binario. */
    fun kind(name: String, data: ByteArray): FilePreviewKind {
        val byName = kind(name)
        return when {
            byName == FilePreviewKind.Image -> FilePreviewKind.Image
            byName == FilePreviewKind.Pdf -> if (isPdf(data)) FilePreviewKind.Pdf else FilePreviewKind.Binary
            byName == FilePreviewKind.Spreadsheet ->
                if (isOfficeContainer(data)) FilePreviewKind.Spreadsheet else FilePreviewKind.Binary
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

    /**
     * Contenedor de una hoja de cálculo: ZIP (xlsx, xlsm, numbers) u OLE2 (xls antiguo). Lo que no
     * lo sea no se entrega al visor del sistema.
     */
    fun isOfficeContainer(data: ByteArray): Boolean = startsWith(data, ZIP_SIGNATURE) || startsWith(data, OLE2_SIGNATURE)

    /** Heurística de binario sobre los primeros 8 KB: no se pueden decodificar como texto. */
    fun looksBinary(data: ByteArray): Boolean = decodeText(data.copyOf(minOf(data.size, SNIFF_BYTES))) == null

    /** Texto a mostrar: el decodificado o, si no lo es, UTF-8 con reemplazos (nunca falla). */
    fun text(data: ByteArray): String = decodeText(data) ?: data.toString(Charsets.UTF_8)

    /**
     * Decodifica texto probando, en orden: BOM UTF-16, UTF-8 (tolera un carácter multibyte cortado
     * al final del bloque leído) y Windows-1252 (o Latin-1), típico de HTML antiguo o exportado.
     * `null` si parece binario: NUL sin BOM UTF-16, o demasiados caracteres de control.
     */
    fun decodeText(data: ByteArray): String? {
        decodeUtf16WithBom(data)?.let { return it }
        val head = data.copyOf(minOf(data.size, SNIFF_BYTES))
        if (head.any { it == 0.toByte() }) return null
        // Un corte a mitad de un carácter multibyte al final no lo hace binario.
        if ((0..3).any { trim -> head.size >= trim && strictDecode(head, head.size - trim, Charsets.UTF_8) != null }) {
            return data.toString(Charsets.UTF_8)
        }
        val legacy = strictDecode(data, data.size, WINDOWS_1252) ?: data.toString(Charsets.ISO_8859_1)
        return legacy.takeUnless { hasTooManyControlCharacters(it, SNIFF_BYTES) }
    }

    /** UTF-16 solo con BOM explícito (sin BOM es indistinguible de un binario con NUL). */
    private fun decodeUtf16WithBom(data: ByteArray): String? {
        if (!startsWith(data, bytes(0xFF, 0xFE)) && !startsWith(data, bytes(0xFE, 0xFF))) return null
        // Un bloque truncado puede acabar a mitad de una unidad de 16 bits.
        val even = data.size - data.size % 2
        // `UTF_16` lee el BOM para elegir el orden de bytes y lo quita del texto, como Apple.
        val text = strictDecode(data, even, Charsets.UTF_16) ?: return null
        return text.takeUnless { hasTooManyControlCharacters(it, SNIFF_BYTES / 2) }
    }

    /** Más de un 2 % de controles C0/C1 (salvo tab, saltos, form feed y ESC) en los primeros [limit] caracteres. */
    private fun hasTooManyControlCharacters(text: String, limit: Int): Boolean {
        var total = 0
        var controls = 0
        var index = 0
        while (index < text.length && total < limit) {
            val scalar = text.codePointAt(index)
            index += Character.charCount(scalar)
            total += 1
            val isControl = scalar < 0x20 || scalar in 0x7F..0x9F
            if (isControl && scalar !in ALLOWED_CONTROLS) controls += 1
        }
        return total > 0 && controls * CONTROL_RATIO > total
    }

    private fun strictDecode(bytes: ByteArray, length: Int, charset: Charset): String? {
        val decoder = charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes, 0, length)).toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }

    private fun startsWith(data: ByteArray, prefix: ByteArray): Boolean =
        data.size >= prefix.size && prefix.indices.all { data[it] == prefix[it] }

    private fun bytes(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }
}
