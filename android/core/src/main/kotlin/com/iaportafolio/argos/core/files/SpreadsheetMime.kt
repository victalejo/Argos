package com.iaportafolio.argos.core.files

/**
 * Tipo MIME con el que se ofrece una hoja de cálculo a otra app («Abrir con…»): la app destino lo
 * usa para decidir si sabe abrirla. Desconocido = genérico (el selector enseña todas las apps).
 */
object SpreadsheetMime {
    const val GENERIC = "application/octet-stream"

    private val BY_EXTENSION = mapOf(
        "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xlsm" to "application/vnd.ms-excel.sheet.macroEnabled.12",
        "xls" to "application/vnd.ms-excel",
        "ods" to "application/vnd.oasis.opendocument.spreadsheet",
        "numbers" to "application/vnd.apple.numbers",
    )

    fun of(name: String): String = BY_EXTENSION[RemotePath.fileExtension(name.lowercase())] ?: GENERIC
}
