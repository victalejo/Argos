package com.iaportafolio.argos.core.files

/**
 * Resaltado de sintaxis LIGERO (port de `ArgosCore/Files/SyntaxHighlighter.swift`): un escáner
 * de una pasada que reconoce comentarios, cadenas, números y palabras clave. No es un parser:
 * busca que el código se lea bien, no exactitud de compilador. Lógica pura; la vista traduce
 * cada [Token.Kind] a un color del tema.
 *
 * Los rangos son índices de `String` de Kotlin, que ya son unidades UTF-16 (como `NSRange`).
 */
object SyntaxHighlighter {

    data class Token(val kind: Kind, val start: Int, val length: Int) {
        enum class Kind { COMMENT, STRING, NUMBER, KEYWORD }

        val end: Int get() = start + length
    }

    /** Por encima de esto no se resalta (el texto se muestra plano, sin coste). */
    const val MAX_HIGHLIGHTED_LENGTH = 300_000

    private class Syntax(
        val lineComments: List<String> = emptyList(),
        val blockComment: Pair<String, String>? = null,
        val quotes: Set<Char> = setOf('"', '\''),
        val keywords: Set<String> = emptySet(),
    )

    private val cFamilyKeywords: Set<String> = setOf(
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
        "return", "true", "false", "null", "new", "class", "struct", "enum", "import",
        "export", "const", "static", "public", "private", "protected", "void", "try",
        "catch", "throw", "finally", "this", "super", "extends", "implements", "interface",
    )

    private val C_BLOCK = "/*" to "*/"

    @Suppress("CyclomaticComplexMethod", "LongMethod") // tabla de lenguajes, como en Swift
    private fun syntax(language: String?): Syntax? = when (language) {
        "swift" -> Syntax(
            listOf("//"), C_BLOCK, setOf('"'),
            cFamilyKeywords + setOf(
                "func", "let", "var", "guard", "in", "init", "self", "Self", "nil", "async",
                "await", "throws", "some", "any", "protocol", "extension", "where", "defer",
                "inout", "final", "override", "mutating", "actor", "fileprivate", "internal",
            ),
        )
        "typescript", "javascript" -> Syntax(
            listOf("//"), C_BLOCK, setOf('"', '\'', '`'),
            cFamilyKeywords + setOf(
                "function", "let", "var", "async", "await", "of", "in", "typeof", "instanceof",
                "undefined", "from", "as", "type", "yield", "delete", "readonly", "keyof",
            ),
        )
        "python" -> Syntax(
            listOf("#"), null, setOf('"', '\''),
            setOf(
                "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
                "and", "or", "is", "None", "True", "False", "import", "from", "as", "with",
                "try", "except", "finally", "raise", "lambda", "yield", "async", "await",
                "pass", "break", "continue", "self", "global", "nonlocal",
            ),
        )
        "go" -> Syntax(
            listOf("//"), C_BLOCK, setOf('"', '\'', '`'),
            cFamilyKeywords + setOf(
                "func", "package", "var", "type", "map", "chan", "go", "defer", "range",
                "select", "nil", "iota", "fallthrough", "goto",
            ),
        )
        "rust" -> Syntax(
            listOf("//"), C_BLOCK, setOf('"'),
            cFamilyKeywords + setOf(
                "fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "match", "loop",
                "self", "Self", "crate", "where", "async", "await", "move", "ref", "Some", "None", "Ok", "Err",
            ),
        )
        "java", "kotlin", "csharp", "c", "cpp", "dart", "php" -> Syntax(
            listOf("//"), C_BLOCK, setOf('"', '\''),
            cFamilyKeywords + setOf(
                "int", "long", "float", "double", "char", "bool", "boolean", "string",
                "fun", "val", "var", "function", "namespace", "using", "include", "define",
            ),
        )
        "ruby" -> Syntax(
            listOf("#"), null, setOf('"', '\''),
            setOf(
                "def", "end", "class", "module", "if", "elsif", "else", "unless", "while",
                "do", "return", "nil", "true", "false", "self", "require", "yield", "begin", "rescue",
            ),
        )
        "shell" -> Syntax(
            listOf("#"), null, setOf('"', '\''),
            setOf(
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                "case", "esac", "function", "return", "export", "local", "echo", "exit",
                "FROM", "RUN", "COPY", "WORKDIR", "CMD", "ENV", "EXPOSE", "ENTRYPOINT", "ARG",
            ),
        )
        "yaml", "toml" -> Syntax(listOf("#"), null, setOf('"', '\''), setOf("true", "false", "null", "yes", "no"))
        "json" -> Syntax(quotes = setOf('"'), keywords = setOf("true", "false", "null"))
        "sql" -> Syntax(
            listOf("--"), C_BLOCK, setOf('\'', '"'),
            setOf(
                "select", "from", "where", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "alter", "drop", "join", "left", "right", "inner",
                "on", "and", "or", "not", "null", "primary", "key", "references", "index",
                "group", "by", "order", "limit", "as", "distinct", "returning",
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "JOIN", "ON", "AND", "OR",
                "NOT", "NULL", "PRIMARY", "KEY", "REFERENCES", "GROUP", "BY", "ORDER", "LIMIT", "AS",
            ),
        )
        "html" -> Syntax(blockComment = "<!--" to "-->")
        "css" -> Syntax(blockComment = C_BLOCK)
        else -> null
    }

    /** Tokens del texto para [language] (`null`/desconocido o texto enorme → sin tokens). */
    fun tokens(text: String, language: String?): List<Token> {
        val syntax = syntax(language) ?: return emptyList()
        if (text.length > MAX_HIGHLIGHTED_LENGTH) return emptyList()
        return Scanner(text, syntax).scan()
    }

    private class Scanner(private val text: String, private val syntax: Syntax) {
        private val count = text.length
        private val tokens = ArrayList<Token>()

        fun scan(): List<Token> {
            var index = 0
            while (index < count) {
                index = scanAt(index)
            }
            return tokens
        }

        /** Consume lo que empiece en [index] y devuelve la siguiente posición. */
        private fun scanAt(index: Int): Int {
            val unit = text[index]
            syntax.lineComments.firstOrNull { text.startsWith(it, index) }?.let { marker ->
                var end = index + marker.length
                while (end < count && text[end] != NEWLINE) end++
                return emit(Token.Kind.COMMENT, index, end)
            }
            syntax.blockComment?.takeIf { text.startsWith(it.first, index) }?.let { (open, close) ->
                var end = index + open.length
                while (end < count && !text.startsWith(close, end)) end++
                return emit(Token.Kind.COMMENT, index, minOf(count, end + close.length))
            }
            if (unit in syntax.quotes) return emit(Token.Kind.STRING, index, stringEnd(index, unit))
            if (unit in '0'..'9' && (index == 0 || !isIdentifier(text[index - 1]))) {
                var end = index + 1
                while (end < count && (isIdentifier(text[end]) || text[end] == '.')) end++ // dígitos, ., x, e…
                return emit(Token.Kind.NUMBER, index, end)
            }
            if (isIdentifier(unit)) {
                var end = index + 1
                while (end < count && isIdentifier(text[end])) end++
                if (syntax.keywords.isNotEmpty() && text.substring(index, end) in syntax.keywords) {
                    emit(Token.Kind.KEYWORD, index, end)
                }
                return end
            }
            return index + 1
        }

        /** Fin de una cadena (respeta escapes; las de comillas simples/dobles no cruzan líneas). */
        private fun stringEnd(index: Int, quote: Char): Int {
            val multiline = quote == '`'
            var end = index + 1
            while (end < count && text[end] != quote) {
                if (text[end] == '\\') {
                    end++ // escapa el siguiente
                } else if (text[end] == NEWLINE && !multiline) {
                    break
                }
                end++
            }
            return minOf(count, end + 1)
        }

        private fun emit(kind: Token.Kind, start: Int, end: Int): Int {
            tokens += Token(kind, start, end - start)
            return end
        }

        /** Como `CharacterSet.alphanumerics` + '_' sobre una unidad UTF-16. */
        private fun isIdentifier(unit: Char): Boolean = unit == '_' || Character.isLetterOrDigit(unit)
    }

    private const val NEWLINE = '\n'
}
