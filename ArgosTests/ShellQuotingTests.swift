//
//  ShellQuotingTests.swift
//  ArgosTests
//
//  La frontera anti-inyección de comandos: shellSingleQuoted debe producir un
//  ÚNICO argumento literal para un shell POSIX, sin importar qué metacaracteres
//  contenga el nombre. Estos tests fijan ese contrato.
//

import Testing
@testable import Argos

@Suite("Shell quoting (anti-inyección)")
struct ShellQuotingTests {

    @Test("Texto simple se envuelve en comillas simples")
    func simple() {
        #expect(ShellQuoting.singleQuoted("main") == "'main'")
    }

    @Test("Cadena vacía produce comillas vacías (sigue siendo un argumento)")
    func empty() {
        #expect(ShellQuoting.singleQuoted("") == "''")
    }

    @Test("Una comilla simple interna se escapa con la secuencia '\\''")
    func internalQuote() {
        // entrada: a'b  ->  'a'\''b'
        #expect(ShellQuoting.singleQuoted("a'b") == "'a'\\''b'")
    }

    @Test(
        "Metacaracteres de shell quedan literales dentro de las comillas",
        arguments: [
            "a b",            // espacio
            "a;rm -rf /",     // separador de comandos
            "a&&b",           // AND lógico
            "a|b",            // pipe (también rompería el parser de list-sessions)
            "$(whoami)",      // sustitución de comando
            "`id`",           // backticks
            "a$VAR",          // expansión de variable
            "a\nb",           // newline embebido
            "a\\b"            // backslash
        ]
    )
    func metacharactersStayLiteral(input: String) {
        let quoted = ShellQuoting.singleQuoted(input)
        // Empieza y termina en comilla simple.
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        // No introduce comillas simples sin escapar: el único modo de "salir"
        // de las comillas es la secuencia '\'' — verificamos que cualquier
        // comilla simple del input fue transformada en esa secuencia.
        if !input.contains("'") {
            // Sin comillas internas: el contenido va tal cual entre comillas.
            #expect(quoted == "'" + input + "'")
        }
    }

    @Test("Cada comilla simple se escapa independientemente")
    func multipleQuotes() {
        let esc = "'\\''" // secuencia POSIX que representa UNA comilla simple
        #expect(ShellQuoting.singleQuoted("''") == "'" + esc + esc + "'")
    }
}
