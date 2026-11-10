package com.iaportafolio.argos.core.ports

import com.iaportafolio.argos.core.ShellQuoting

/**
 * Un puerto TCP en escucha en el servidor (port de `ArgosCore/PortForwarding/ListeningPort.swift`):
 * lo que se puede reenviar al dispositivo.
 *
 * @property targetHost host al que pide conectar el túnel en el servidor: `localhost` si escucha
 *   en loopback o en todas las interfaces; si no, la dirección concreta.
 * @property processName proceso dueño (solo si es del mismo usuario: `ss -p` no ve los ajenos).
 */
data class ListeningPort(val port: Int, val targetHost: String, val processName: String?) {

    /**
     * Puertos de sistema (DNS local, CUPS, sshd…) que no interesa reenviar. Se dejan 80/443 por
     * si un servidor web de desarrollo corre ahí.
     */
    val isLikelyDevServer: Boolean
        get() {
            if (processName == "sshd" || port == 22) return false
            return port >= 1024 || port == 80 || port == 443
        }
}

/** Lee `ss -tln` (o `netstat -tln`). Byte a byte el comando de Apple (golden `ports-listening`). */
object ListeningPortParser {

    private const val SCRIPT = "if command -v ss >/dev/null 2>&1; then\n" +
        "  ss -Htlnp 2>/dev/null || ss -tln\n" +
        "else\n" +
        "  netstat -tln 2>/dev/null\n" +
        "fi"

    /** Comando remoto (solo lectura) bajo `sh`, como `ShellQuoting.posixShell` de Apple. */
    val command: String = "sh -c " + ShellQuoting.singleQuoted(SCRIPT)

    private val wildcardOrLoopback = setOf("", "*", "0.0.0.0", "::", ":", "::1", "localhost")
    private val processRegex = Regex("""\(\("([^"]*)"""")

    fun parse(output: String): List<ListeningPort> {
        val byPort = LinkedHashMap<Int, ListeningPort>()
        for (line in output.lineSequence()) {
            val fields = line.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            val local = localAddressField(fields) ?: continue
            val (address, port) = splitHostPort(local) ?: continue
            val entry = ListeningPort(port, targetHost(address), processName(line))
            val existing = byPort[port]
            if (existing == null) {
                byPort[port] = entry
            } else {
                // IPv4 + IPv6 del mismo puerto: uno. Se prefiere el que dice el proceso y el que
                // llega por `localhost`.
                val better = (existing.processName == null && entry.processName != null) ||
                    (existing.targetHost != "localhost" && entry.targetHost == "localhost")
                if (better) {
                    byPort[port] = ListeningPort(
                        port,
                        if (entry.targetHost == "localhost") "localhost" else existing.targetHost,
                        entry.processName ?: existing.processName,
                    )
                }
            }
        }
        return byPort.values.sortedBy { it.port }
    }

    /**
     * Columna de la dirección local: la 4ª en `ss` (`LISTEN 0 511 *:3000 *:*`) y en `netstat`
     * (`tcp 0 0 0.0.0.0:3000 0.0.0.0:* LISTEN`). Las cabeceras no coinciden.
     */
    private fun localAddressField(fields: List<String>): String? {
        if (fields.size < 4) return null
        val first = fields[0].lowercase()
        if (first == "listen") return fields[3]
        if (first.startsWith("tcp") && fields.last().uppercase() == "LISTEN") return fields[3]
        return null
    }

    /** `127.0.0.1:3000`, `*:3000`, `[::]:3000`, `:::3000`, `127.0.0.53%lo:53`. */
    fun splitHostPort(value: String): Pair<String, Int>? {
        val colon = value.lastIndexOf(':')
        if (colon < 0) return null
        val port = value.substring(colon + 1).toIntOrNull() ?: return null
        if (port !in 1..65535) return null
        var host = value.substring(0, colon)
        val percent = host.indexOf('%')
        if (percent >= 0) host = host.substring(0, percent)
        host = host.trim('[', ']')
        return host to port
    }

    fun targetHost(address: String): String =
        if (address in wildcardOrLoopback || address.startsWith("127.")) "localhost" else address

    /** Primer nombre de `users:(("node",pid=123,fd=20))`. */
    private fun processName(line: String): String? =
        processRegex.find(line)?.groupValues?.get(1)?.takeIf { it.isNotEmpty() }
}
