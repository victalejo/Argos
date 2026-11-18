package com.iaportafolio.argos.core

/**
 * Plazo EN EL SERVIDOR para los comandos de sondeo (port de `ArgosCore/RemoteTimeout.swift`). El
 * plazo local deja de esperar, pero el canal sigue abierto hasta que el comando remoto acabe; si
 * el comando se cuelga (tmux bloqueado, disco que no responde) los canales se acumulan. Con
 * `timeout` de coreutils el propio servidor lo mata antes de que venza el local. Si el servidor no
 * lo tiene (macOS, BusyBox mínimo), el comando corre tal cual.
 */
object RemoteTimeout {

    /** Segundos de los sondeos: por debajo del plazo local de los comandos de fondo. */
    const val POLL_SECONDS = 60

    /** Código con el que `timeout` informa de que mató el comando. */
    const val EXPIRED_EXIT_CODE = 124

    /** [command] (sintaxis POSIX sh) con plazo remoto de [seconds] cuando hay `timeout`. `-k 5`: KILL a los 5 s. */
    fun wrap(command: String, seconds: Int = POLL_SECONDS): String {
        val quoted = ShellQuoting.singleQuoted(command)
        return "if command -v timeout >/dev/null 2>&1; then timeout -k 5 ${maxOf(1, seconds)} sh -c $quoted; " +
            "else sh -c $quoted; fi"
    }
}
