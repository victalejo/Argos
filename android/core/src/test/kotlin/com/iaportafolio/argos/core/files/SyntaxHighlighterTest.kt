package com.iaportafolio.argos.core.files

import com.iaportafolio.argos.core.files.SyntaxHighlighter.Token.Kind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Paridad con la parte de resaltado de `ArgosTests/FileBrowserTests.swift`, y algo más. */
class SyntaxHighlighterTest {

    private fun kinds(text: String, language: String?): List<Pair<Kind, String>> =
        SyntaxHighlighter.tokens(text, language).map { it.kind to text.substring(it.start, it.end) }

    @Test
    fun `swift palabras clave cadenas con escapes comentarios y numeros`() {
        val tokens = kinds("let x = \"a\\\"b\" // fin\nreturn 42 /* b */", "swift")
        assertTrue(Kind.KEYWORD to "let" in tokens)
        assertTrue(Kind.STRING to "\"a\\\"b\"" in tokens)
        assertTrue(Kind.COMMENT to "// fin" in tokens)
        assertTrue(Kind.KEYWORD to "return" in tokens)
        assertTrue(Kind.NUMBER to "42" in tokens)
        assertTrue(Kind.COMMENT to "/* b */" in tokens)
    }

    @Test
    fun `una palabra clave dentro de una cadena o comentario no se resalta aparte`() {
        val tokens = kinds("x = \"return\" # if", "python")
        assertFalse(tokens.any { it.first == Kind.KEYWORD })
        assertEquals(2, tokens.size)
    }

    @Test
    fun `identificadores con digitos no son numeros y lenguaje desconocido no resalta`() {
        assertFalse(kinds("v2 = x3", "javascript").any { it.first == Kind.NUMBER })
        assertTrue(SyntaxHighlighter.tokens("let x = 1", null).isEmpty())
        assertTrue(SyntaxHighlighter.tokens("let x = 1", "cobol").isEmpty())
    }

    @Test
    fun `cadena sin cerrar no se come las lineas siguientes`() {
        assertTrue(Kind.KEYWORD to "return" in kinds("a = 'abc\nreturn b", "python"))
    }

    @Test
    fun `plantillas con backtick si cruzan lineas`() {
        val tokens = kinds("const s = `a\nb`; return", "typescript")
        assertTrue(Kind.STRING to "`a\nb`" in tokens)
        assertTrue(Kind.KEYWORD to "return" in tokens)
    }

    @Test
    fun `comentario de bloque sin cerrar llega hasta el final`() {
        val text = "int a; /* abierto\nreturn"
        assertEquals(listOf(Kind.KEYWORD to "int", Kind.COMMENT to "/* abierto\nreturn"), kinds(text, "kotlin"))
    }

    @Test
    fun `comentarios de html sql y numeros con punto`() {
        assertEquals(listOf(Kind.COMMENT to "<!-- x -->"), kinds("<p><!-- x --></p>", "html"))
        assertTrue(Kind.COMMENT to "-- nota" in kinds("SELECT 1 -- nota", "sql"))
        assertTrue(Kind.NUMBER to "3.14" in kinds("x = 3.14", "python"))
    }

    @Test
    fun `los rangos son UTF-16 como NSRange`() {
        val text = "// 😀\nlet a"
        val tokens = SyntaxHighlighter.tokens(text, "swift")
        assertEquals(SyntaxHighlighter.Token(Kind.COMMENT, 0, 5), tokens.first())
        assertEquals("let", text.substring(tokens[1].start, tokens[1].end))
    }

    @Test
    fun `texto enorme no se resalta`() {
        val huge = "a".repeat(SyntaxHighlighter.MAX_HIGHLIGHTED_LENGTH + 1)
        assertTrue(SyntaxHighlighter.tokens(huge, "swift").isEmpty())
    }
}
