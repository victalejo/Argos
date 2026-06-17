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
}
