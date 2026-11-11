package com.iaportafolio.argos.core.ports

import com.iaportafolio.argos.core.ShellQuoting

/**
 * Cierre automático de túneles sin uso (port de `PortForwardIdlePolicy.swift`). «Sin uso» = ninguna
 * conexión abierta por el túnel durante el límite.
 */
object PortForwardIdlePolicy {
    /** Opciones del selector, en minutos (0 = nunca). */
    val options: List<Int> = listOf(0, 5, 15, 30, 60)
    const val DEFAULT_MINUTES = 15

    /** Límite elegido en este teléfono. Lo fija la app (preferencia) y lo lee el vigilante. */
    @Volatile
    var limitMinutes: Int = DEFAULT_MINUTES
        set(value) {
            field = if (value in options) value else DEFAULT_MINUTES
        }

    /** ¿Hay que cerrar el túnel? Nunca con conexiones abiertas ni con el límite en 0. */
    fun shouldClose(activeConnections: Int, lastActivityMillis: Long, nowMillis: Long, limitMinutes: Int): Boolean {
        if (limitMinutes <= 0 || activeConnections > 0) return false
        return nowMillis - lastActivityMillis >= limitMinutes * 60_000L
    }
}

/** Identidad de este teléfono en los archivos del servidor (la fija la app al arrancar). */
object PortForwardDevice {
    @Volatile var id: String = "android"

    @Volatile var name: String = "Android"
}

/** Conexiones abiertas y última actividad de un túnel (la tocan los hilos de sshj). */
class PortForwardActivity(nowMillis: Long = System.currentTimeMillis()) {
    private var active = 0
    private var lastActivity = nowMillis

    @Synchronized
    fun connectionOpened(nowMillis: Long = System.currentTimeMillis()) {
        active++
        lastActivity = nowMillis
    }

    @Synchronized
    fun connectionClosed(nowMillis: Long = System.currentTimeMillis()) {
        active = maxOf(0, active - 1)
        lastActivity = nowMillis
    }

    @Synchronized
    fun snapshot(): Pair<Int, Long> = active to lastActivity
}

/**
 * Lo que Argos deja en el SERVIDOR para la skill de Claude (port de `PortForwardServerFiles.swift`):
 * el archivo de túneles de este dispositivo, el script `argos-ports` y la skill `argos-puertos`.
 * Byte a byte los comandos de Apple (golden `ports-publish`, `ports-unpublish`, `ports-install`).
 */
object PortForwardServerFiles {

    const val TOOL_VERSION = "argos-ports v3"

    /** Cada cuánto se renueva el archivo mientras hay túneles. */
    const val REFRESH_INTERVAL_MILLIS = 60_000L

    private const val FORWARDS_DIR = "\$HOME/.config/argos/forwards"

    /** Script y skill: recursos copiados de la salida del código Swift. */
    val scriptContent: String by lazy { resource("argos-ports.sh") }
    val skillContent: String by lazy { resource("SKILL.md") }

    private fun resource(name: String): String =
        checkNotNull(PortForwardServerFiles::class.java.getResource("/argos-ports/$name")) { "falta el recurso $name" }
            .readText(Charsets.UTF_8)

    private fun posixShell(script: String): String = "sh -c " + ShellQuoting.singleQuoted(script)

    /** Solo `[A-Za-z0-9-]` (ASCII): el id va en una ruta. */
    fun safeID(id: String): String {
        val cleaned = id.filter { (it in 'a'..'z') || (it in 'A'..'Z') || (it in '0'..'9') || it == '-' }
        return cleaned.ifEmpty { "dispositivo" }
    }

    /** Una línea por túnel: `puertoRemoto<TAB>puertoLocal<TAB>host`. */
    fun forwardLines(forwards: List<ActivePortForward>): String =
        forwards.sortedBy { it.remotePort }.joinToString("") {
            "${it.remotePort}\t${it.localPort}\t${sanitized(it.targetHost)}\n"
        }

    fun publishCommand(deviceID: String, deviceName: String, forwards: List<ActivePortForward>): String {
        val id = safeID(deviceID)
        val q = ShellQuoting::singleQuoted
        return posixShell(
            "d=\"$FORWARDS_DIR\"; mkdir -p \"\$d\" && " +
                "{ printf '%s\\t%s\\n' ${q(sanitized(deviceName))} \"\$(date +%s)\"; printf '%s' ${q(forwardLines(forwards))}; } " +
                "> \"\$d/$id.tmp\" && mv \"\$d/$id.tmp\" \"\$d/$id.tsv\"",
        )
    }

    fun unpublishCommand(deviceID: String): String = posixShell("rm -f \"$FORWARDS_DIR/${safeID(deviceID)}.tsv\"")

    /**
     * Instala la skill y su script (DENTRO de la skill: si `~/.claude` se sincroniza entre equipos,
     * viajan juntos) si faltan o son de otra versión. Idempotente; borra el script de la v1.
     */
    val installCommand: String by lazy {
        val dir = "\$HOME/.claude/skills/argos-puertos"
        val script = "$dir/argos-ports"
        val skill = "$dir/SKILL.md"
        val version = ShellQuoting.singleQuoted(TOOL_VERSION)
        posixShell(
            "grep -qs $version \"$script\" && grep -qs $version \"$skill\" && exit 0\n" +
                "mkdir -p \"$dir\" || exit 1\n" +
                "cat > \"$script\" <<'ARGOS_PORTS_SCRIPT'\n${scriptContent}ARGOS_PORTS_SCRIPT\n" +
                "chmod 755 \"$script\" || exit 1\n" +
                "cat > \"$skill\" <<'ARGOS_PORTS_SKILL'\n${skillContent}ARGOS_PORTS_SKILL\n" +
                "rm -f \"\$HOME/.config/argos/bin/argos-ports\"\n",
        )
    }

    // MARK: Solicitudes de Claude («argos-ports open PUERTO [NOTA]»)

    /** Una solicitud caduca a los 10 minutos (el script y Argos la ignoran). */
    const val REQUEST_MAX_AGE_SECONDS = 600

    private const val REQUESTS_DIR = "\$HOME/.config/argos/forward-requests"

    /** Hora del servidor y una línea por solicitud: `puerto<TAB>creada<TAB>nota`. Borra las caducadas. */
    val listRequestsCommand: String = posixShell(
        "r=\"$REQUESTS_DIR\"; find \"\$r\" -name '*.req' -mmin +10 -exec rm -f {} + 2>/dev/null; " +
            "date +%s; for f in \"\$r\"/*.req; do [ -f \"\$f\" ] || continue; " +
            "p=\${f##*/}; printf '%s\\t' \"\${p%.req}\"; head -n 1 \"\$f\"; done",
    )

    /** Retira una solicitud (aceptada o rechazada). */
    fun dismissRequestCommand(port: Int): String = posixShell("rm -f \"$REQUESTS_DIR/$port.req\"")

    private fun sanitized(text: String): String = text.replace('\t', ' ').replace('\n', ' ')
}
