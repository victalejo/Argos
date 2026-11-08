package com.iaportafolio.argos.ui.files

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import com.iaportafolio.argos.core.files.SyntaxHighlighter

/** Colores del resaltado (como `CodeHighlight` de iOS: gris, rojo, índigo y morado del sistema). */
data class CodePalette(val comment: Color, val string: Color, val number: Color, val keyword: Color) {
    fun of(kind: SyntaxHighlighter.Token.Kind): Color = when (kind) {
        SyntaxHighlighter.Token.Kind.COMMENT -> comment
        SyntaxHighlighter.Token.Kind.STRING -> string
        SyntaxHighlighter.Token.Kind.NUMBER -> number
        SyntaxHighlighter.Token.Kind.KEYWORD -> keyword
    }

    companion object {
        val Light = CodePalette(Color(0xFF8E8E93), Color(0xFFD12F1B), Color(0xFF5856D6), Color(0xFFAD3DA4))
        val Dark = CodePalette(Color(0xFF98989D), Color(0xFFFF8170), Color(0xFFA7A5FF), Color(0xFFFF7AB2))
    }
}

/**
 * Líneas del código como `AnnotatedString` con los colores de [tokens] (una por línea, para
 * pintarlas en una lista perezosa: un archivo de 2 MB no cabe en un solo `Text`).
 */
fun highlightedLines(text: String, tokens: List<SyntaxHighlighter.Token>, palette: CodePalette): List<AnnotatedString> {
    val full = buildAnnotatedString {
        append(text)
        tokens.forEach { addStyle(SpanStyle(color = palette.of(it.kind)), it.start, it.end.coerceAtMost(text.length)) }
    }
    val lines = ArrayList<AnnotatedString>()
    var start = 0
    while (true) {
        val newline = text.indexOf('\n', start)
        if (newline < 0) {
            lines += full.subSequence(start, text.length)
            return lines
        }
        lines += full.subSequence(start, newline)
        start = newline + 1
    }
}
