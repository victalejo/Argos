package com.iaportafolio.argos.core

/**
 * Entrecomillado de argumentos para un shell POSIX (port de `ArgosCore/ShellQuoting.swift`).
 *
 * Es la frontera anti-inyección de comandos: todo lo que el usuario escribe y acaba en un
 * comando remoto (nombres de sesión, rutas, carpetas) pasa por aquí.
 */
object ShellQuoting {

    /**
     * Envuelve [value] en comillas simples, escapando las internas con la secuencia
     * canónica `'\''`. El resultado es UN ÚNICO argumento literal: ningún metacarácter
     * (`$`, `` ` ``, `;`, `|`, `&`, espacios, saltos de línea…) se interpreta. Una cadena
     * vacía produce `''` (sigue siendo un argumento explícito).
     */
    fun singleQuoted(value: String): String = "'" + value.replace("'", "'\\''") + "'"
}
