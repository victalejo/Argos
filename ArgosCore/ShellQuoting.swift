//
//  ShellQuoting.swift
//  Argos
//
//  Utilidad pura de entrecomillado para shells POSIX. Extraída de la extensión
//  del PTY para que tanto la gestión de sesiones (SSHSessionManagement) como el
//  terminal en vivo (SSHTerminalSession) dependan de una primitiva neutral y
//  testeable en aislamiento (es la frontera anti-inyección de comandos).
//

import Foundation

/// Entrecomillado de argumentos para un shell POSIX.
enum ShellQuoting {

    /// Envuelve `value` en comillas simples, escapando las comillas simples
    /// internas con la secuencia canónica `'\''`.
    ///
    /// Garantiza que el resultado sea UN ÚNICO argumento literal: ningún
    /// metacarácter del shell (`$`, `` ` ``, `;`, `|`, `&`, espacios, saltos de
    /// línea, etc.) se interpreta. Una cadena vacía produce `''` (sigue siendo
    /// un argumento explícito, no la ausencia de argumento).
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Ejecuta `script` con `sh` (POSIX), sea cual sea el shell de login del usuario.
    /// Por SSH, el comando lo interpreta el shell de login: con zsh, un comodín sin
    /// coincidencias (`dir/*/`) aborta el script («no matches found») y las variables
    /// sin comillas no se parten por espacios. Los scripts de Argos son POSIX: deben
    /// correr siempre bajo `sh`.
    static func posixShell(_ script: String) -> String {
        "sh -c " + singleQuoted(script)
    }
}
