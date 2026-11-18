//
//  RemoteTimeout.swift
//  ArgosCore
//
//  Plazo EN EL SERVIDOR para los comandos de sondeo. El plazo local (`CommandTimeout`)
//  deja de esperar, pero el canal sigue abierto hasta que el comando remoto acabe; si el
//  comando se cuelga (tmux bloqueado, disco que no responde) los canales se acumulan.
//  Con `timeout` de coreutils el propio servidor lo mata antes de que venza el local.
//  Si el servidor no lo tiene (macOS, BusyBox mínimo), el comando corre tal cual.
//

import Foundation

enum RemoteTimeout {

    /// Segundos de los sondeos: por debajo del plazo local normal (90 s).
    static let pollSeconds = 60

    /// Código con el que `timeout` informa de que mató el comando.
    static let expiredExitCode = 124

    /// `command` (sintaxis POSIX sh) con plazo remoto de `seconds` cuando hay `timeout`.
    /// `-k 5`: si no atiende a TERM, KILL a los 5 s.
    static func wrap(_ command: String, seconds: Int = pollSeconds) -> String {
        let quoted = ShellQuoting.singleQuoted(command)
        return "if command -v timeout >/dev/null 2>&1; then timeout -k 5 \(max(1, seconds)) sh -c \(quoted); "
            + "else sh -c \(quoted); fi"
    }
}
