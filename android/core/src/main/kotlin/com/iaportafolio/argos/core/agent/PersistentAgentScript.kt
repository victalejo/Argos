package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Un agente persistente tal como lo lista el servidor. */
data class PersistentAgentInfo(
    val id: String,
    val isAlive: Boolean,
    /** Bytes ABSOLUTOS del log (incluidos los rotados). */
    val logBytes: Long,
    val meta: PersistentAgentMeta,
)

/**
 * Agente PERSISTENTE en el servidor (port BYTE A BYTE de `ArgosCore/Agent/PersistentAgentScript.swift`):
 * `claude` corre desacoplado de la conexión SSH y sigue trabajando aunque el móvil se bloquee o
 * cambie de red.
 *
 * Cada agente vive en `~/.config/argos/agents/<id>/` (id = session id de Claude):
 * - `in`: FIFO por la que se le escribe; claude la abre en lectura-escritura (`0<>`).
 * - `out.ndjson`: todo lo que emite claude + una marca por cada permiso respondido.
 * - `pid`, `meta.json`, `err.log`.
 * - (aditivos) `log.base` y `"hibernatedAt"` en `meta.json`: ver [PersistentAgentShell].
 */
object PersistentAgentScript {

    const val ROOT_RELATIVE_PATH = ".config/argos/agents"

    /** Marca que Argos anexa al log al responder un permiso. */
    const val ANSWERED_EVENT_TYPE = "argos_permission_answered"

    /** Primera línea que imprime [attach] (no está en el log): base de rotación y byte local. */
    const val LOG_BASE_EVENT_TYPE = "argos_log_base"

    // Respuestas del lanzador y del envío por stdin (primera línea de stdout).
    const val ALIVE_REPLY = "ARGOS_AGENT_ALIVE"
    const val BUSY_REPLY = "ARGOS_AGENT_BUSY"
    const val DEAD_REPLY = "ARGOS_AGENT_DEAD"
    const val FAILED_REPLY = "ARGOS_AGENT_FAILED"
    const val SENT_REPLY = "ARGOS_SENT"
    const val SHORT_REPLY = "ARGOS_SEND_SHORT"
    const val TIMEOUT_REPLY = "ARGOS_SEND_TIMEOUT"
    const val HIBERNATED_REPLY = "ARGOS_HIBERNATED"

    /**
     * Línea máxima (bytes) que va dentro del comando: muy por debajo del búfer de una FIFO
     * (64 KiB en Linux) y del límite de 128 KiB por argumento. Las mayores van por stdin.
     */
    const val MAX_INLINE_LINE_BYTES = 16 * 1024

    /** Segundos que el escritor vigilado espera a que claude lea la línea. */
    const val SEND_TIMEOUT_SECONDS = 30

    /** Bytes del final de `err.log` que se muestran cuando el agente no arranca. */
    const val ERROR_TAIL_BYTES = 1_500

    /** Líneas del final del log que bastan para saber el estado (avisos). */
    const val ATTENTION_TAIL_LINES = 30

    /** Cada línea se recorta a esto (un permiso de un `Write` puede ocupar cientos de KB). */
    const val ATTENTION_LINE_BYTES = 400

    private val UUID_PATTERN = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    /** Los ids son UUID (`UUID(uuidString:)`): nada más debe llegar al shell. */
    fun isValidID(id: String): Boolean = UUID_PATTERN.matches(id)

    /**
     * `"$HOME/.config/argos/agents/<id>"` (entre comillas dobles: `$HOME` se expande).
     *
     * @throws IllegalArgumentException si [id] no es un UUID (error de programación).
     */
    fun directory(id: String): String {
        require(isValidID(id)) { "id de agente no válido" }
        return "\"\$HOME/$ROOT_RELATIVE_PATH/$id\""
    }

    /**
     * Comprueba que el `pid` guardado es DE VERDAD este agente (y lo deja en `$p`): tras un
     * reinicio ese número puede ser de otro proceso. La línea de comandos de claude lleva el id.
     */
    fun aliveCheck(id: String): String {
        val dir = directory(id)
        return "{ p=\$(cat $dir/pid 2>/dev/null); [ -n \"\$p\" ] && ps -o args= -p \"\$p\" 2>/dev/null | grep -q -- '$id'; }"
    }

    // MARK: Lanzar

    /**
     * Arranca el agente (o lo REANUDA) en segundo plano e imprime su PID; si ya está vivo, no
     * lanza otro e imprime `ARGOS_AGENT_ALIVE`. Si muere nada más arrancar, imprime
     * `ARGOS_AGENT_FAILED <final de err.log en base64>`.
     *
     * La PRIMERA línea de stdin es el token OAuth (o vacía). Con el agente parado y el cerrojo
     * cogido se recortan los logs; con [hibernation] activa, un vigilante lo hiberna si se
     * queda quieto ese tiempo.
     */
    fun launch(
        id: String,
        meta: PersistentAgentMeta,
        claudeInvocation: String,
        hibernation: PersistentAgentHibernation = PersistentAgentHibernation.STANDARD,
    ): String {
        val dir = directory(id)
        val metaB64 = SwiftText.encodeBase64(PersistentAgentMeta.encode(meta).toByteArray(Charsets.UTF_8))
        val cd = ClaudeAgentCommand.cdTarget(meta.workingDirectory)
        // El token se exporta con un builtin (nunca como argumento) y se borra la copia.
        val inner = listOf(
            "[ -n \"\$ARGOS_OAUTH\" ] && export CLAUDE_CODE_OAUTH_TOKEN=\"\$ARGOS_OAUTH\"",
            "unset ARGOS_OAUTH",
            "cd $cd && exec $claudeInvocation 0<>$dir/in >>$dir/out.ndjson 2>>$dir/err.log",
        ).joinToString("; ")
        // umask 077 en un SUBSHELL: la carpeta queda privada, claude conserva el umask normal.
        val prepare = "( umask 077 && mkdir -p $dir && cd $dir && { [ -p in ] || mkfifo in; } " +
            "&& printf '%s' '$metaB64' | base64 -d > meta.json && touch out.ndjson err.log )"
        val spawn = "{ command -v setsid >/dev/null 2>&1 && S=setsid || S=; } && " +
            "{ nohup \$S sh -c ${ShellQuoting.singleQuoted(inner)} >/dev/null 2>&1 < /dev/null & echo \$! > $dir/pid; }"
        // Si claude muere al arrancar (opción desconocida, binario roto…), se dice por qué.
        val verify = "P=\$(cat $dir/pid); sleep 1; if ! kill -0 \"\$P\" 2>/dev/null; then " +
            "printf '%s %s\\n' $FAILED_REPLY \"\$(tail -c $ERROR_TAIL_BYTES $dir/err.log 2>/dev/null | base64 | tr -d '\\n')\"; " +
            "rm -f $dir/pid; exit 6; fi"
        val lock = PersistentAgentShell.lockPath(id)
        // Vivo: se reescribe `meta.json` igualmente (quita una marca `hibernatedAt` de una
        // hibernación que no llegó a pararlo).
        val alive = "if ${aliveCheck(id)}; then " +
            "( umask 077 && printf '%s' '$metaB64' | base64 -d > $dir/meta.json.tmp ) && mv $dir/meta.json.tmp $dir/meta.json; " +
            "echo $ALIVE_REPLY; exit 0; fi"
        val lines = mutableListOf(
            "IFS= read -r ARGOS_OAUTH; export ARGOS_OAUTH",
            "mkdir -p \"\$HOME/$ROOT_RELATIVE_PATH\" && chmod 700 \"\$HOME/$ROOT_RELATIVE_PATH\"",
            // Un cerrojo de más de un minuto es de un lanzamiento que se interrumpió.
            "find \"\$HOME/$ROOT_RELATIVE_PATH\" -maxdepth 1 -name '.$id.lock' -mmin +1 -exec rmdir {} \\; 2>/dev/null",
            PersistentAgentShell.acquireLock(id, PersistentAgentShell.LOCK_WAIT_SECONDS, "echo $BUSY_REPLY; exit 4"),
            "trap 'rmdir $lock 2>/dev/null' EXIT",
            alive,
            "$prepare || exit 1",
            // Agente parado y cerrojo cogido: momento seguro para recortar los logs.
            PersistentAgentShell.rotateOutputLog(dir),
            PersistentAgentShell.trimErrorLog(dir),
            "$spawn || exit 1",
            verify,
        )
        if (hibernation.isEnabled) {
            val watch = PersistentAgentShell.watchdog(id, hibernation.idleSeconds, hibernation.checkSeconds)
            lines += "nohup \$S sh -c ${ShellQuoting.singleQuoted(watch)} argos-watch \"\$P\" >/dev/null 2>&1 < /dev/null &"
        }
        lines += "echo \"\$P\""
        return lines.joinToString("\n")
    }

    /** ¿Es [line] una respuesta del lanzador? (lo demás es ruido del perfil del shell) */
    fun isLaunchReply(line: String): Boolean =
        line == BUSY_REPLY || line == ALIVE_REPLY || line.startsWith(FAILED_REPLY) || line.toIntOrNull() != null

    /**
     * Interpreta la primera línea del lanzador (como `PersistentAgentSession.parseLaunchReply`).
     *
     * @throws PersistentAgentException ocupado o claude murió al arrancar (con el final de `err.log`).
     * @throws AgentExecException cualquier otra respuesta.
     */
    fun parseLaunchReply(reply: String) {
        if (reply == BUSY_REPLY) throw PersistentAgentException(PersistentAgentError.BUSY)
        if (reply.startsWith(FAILED_REPLY)) {
            val encoded = SwiftText.trimWhitespace(reply.substring(FAILED_REPLY.length))
            val detail = SwiftText.decodeBase64(encoded)?.toString(Charsets.UTF_8) ?: ""
            throw PersistentAgentException(PersistentAgentError.LAUNCH_FAILED, detail.takeLast(ERROR_TAIL_BYTES))
        }
        if (reply != ALIVE_REPLY && reply.toIntOrNull() == null) {
            throw AgentExecException("No se pudo arrancar el agente en el servidor (respuesta: ${reply.take(200)}).")
        }
    }

    // MARK: Enviar

    /**
     * Escribe una línea NDJSON en la FIFO del agente, en base64 (nunca se interpreta en el
     * shell). Con [answeredRequestID] (respuesta a un permiso), DESPUÉS de entregarla se anota
     * en el log que ya se respondió. Para líneas grandes (ver [needsStdin]) se usa [sendViaStdin].
     */
    fun send(id: String, line: String, answeredRequestID: String? = null): String {
        val dir = directory(id)
        val b64 = SwiftText.encodeBase64("$line\n".toByteArray(Charsets.UTF_8))
        val command = "${deliverable(id)} || { echo '$DEAD_REPLY' >&2; exit 3; }; " +
            "exec 3<>$dir/in && printf '%s' '$b64' | base64 -d >&3"
        if (answeredRequestID == null) return command
        return "$command && ${appendAnsweredMarker(dir, answeredRequestID)}"
    }

    /**
     * Vivo Y no hibernándose: con `hibernatedAt` el vigilante ya lo está parando y lo escrito se
     * perdería (el cliente lo reanuda y reenvía).
     */
    fun deliverable(id: String): String =
        "{ ${aliveCheck(id)} && ! ${PersistentAgentShell.isMarkedHibernated(directory(id))}; }"

    /** ¿La línea es demasiado grande para ir dentro del comando? */
    fun needsStdin(line: String): Boolean = line.toByteArray(Charsets.UTF_8).size + 1 > MAX_INLINE_LINE_BYTES

    /**
     * Variante para líneas grandes: la línea llega por la ENTRADA ESTÁNDAR del canal, se guarda
     * en un archivo privado, se comprueba que llegó entera ([byteCount] = bytes con su `\n`) y
     * solo entonces se escribe en la FIFO, en SEGUNDO PLANO y vigilada (muerte del agente o
     * plazo). Responde por stdout con `ARGOS_SENT`, `ARGOS_AGENT_DEAD`, `ARGOS_SEND_SHORT` o
     * `ARGOS_SEND_TIMEOUT`.
     */
    fun sendViaStdin(
        id: String,
        byteCount: Int,
        answeredRequestID: String? = null,
        timeoutSeconds: Int = SEND_TIMEOUT_SECONDS,
    ): String {
        val dir = directory(id)
        val file = "$dir/.send.\$\$"
        val ticks = maxOf(1, timeoutSeconds) * 5
        val lines = mutableListOf(
            "${deliverable(id)} || { echo $DEAD_REPLY; exit 3; }",
            "( umask 077 && head -n 1 > $file )",
            "n=\$(wc -c < $file | tr -d ' ')",
            "if [ \"\$n\" != \"$byteCount\" ]; then rm -f $file; echo $SHORT_REPLY; exit 7; fi",
            "exec 3<>$dir/in || { rm -f $file; exit 1; }",
            "cat $file >&3 & w=\$!",
            "i=0; while kill -0 \"\$w\" 2>/dev/null; do",
            "if ! ${aliveCheck(id)}; then kill \"\$w\" 2>/dev/null; rm -f $file; echo $DEAD_REPLY; exit 3; fi",
            "if [ \$i -ge $ticks ]; then kill \"\$w\" 2>/dev/null; rm -f $file; echo $TIMEOUT_REPLY; exit 8; fi",
            "sleep 0.2; i=\$((i+1)); done",
            "wait \"\$w\"; r=\$?; rm -f $file; [ \$r -eq 0 ] || exit 1",
        )
        if (answeredRequestID != null) lines += "${appendAnsweredMarker(dir, answeredRequestID)} || exit 1"
        lines += "echo $SENT_REPLY"
        return lines.joinToString("\n")
    }

    private fun appendAnsweredMarker(dir: String, requestID: String): String {
        // Igual que `JSONSerialization` con `.sortedKeys` (escapa `/`).
        val marker = SwiftJson.compact(
            JsonObject(mapOf("type" to JsonPrimitive(ANSWERED_EVENT_TYPE), "request_id" to JsonPrimitive(requestID))),
            escapeSlashes = true,
            numbers = SwiftJson.Numbers.PRINTF_17G,
        )
        val markerB64 = SwiftText.encodeBase64("$marker\n".toByteArray(Charsets.UTF_8))
        return "printf '%s' '$markerB64' | base64 -d >> $dir/out.ndjson"
    }

    // MARK: Enganche

    /**
     * Sigue el log desde el byte ABSOLUTO [fromByte] (1 = desde el principio). Antes de los datos
     * imprime UNA línea `{"type":"argos_log_base","base":B,"from":S}`: `B` son los bytes rotados
     * y `S` el byte local desde el que sigue (si lo pedido ya se rotó o queda más allá del final,
     * `S` = 1 y el cliente reconstruye). El `tail` muere al cerrarse el canal SSH (EOF en stdin).
     */
    fun attach(id: String, fromByte: Long = 1): String {
        val dir = directory(id)
        return "w=0; while [ -e $dir/.rotating ] && [ \$w -lt 50 ]; do sleep 0.2; w=\$((w+1)); done; " +
            "${PersistentAgentShell.readBase(dir)}; s=\$((${maxOf(1L, fromByte)} - b)); [ \"\$s\" -ge 1 ] || s=1; " +
            "sz=\$(wc -c < $dir/out.ndjson 2>/dev/null | tr -d ' '); [ \"\$s\" -le \$(( \${sz:-0} + 1 )) ] || s=1; " +
            "printf '{\"type\":\"$LOG_BASE_EVENT_TYPE\",\"base\":%s,\"from\":%s}\\n' \"\$b\" \"\$s\"; " +
            "tail -c +\"\$s\" -F $dir/out.ndjson 2>/dev/null & T=\$!; " +
            "trap 'kill \$T 2>/dev/null' EXIT HUP TERM; cat > /dev/null; kill \$T 2>/dev/null"
    }

    /** Cabecera de [attach]: (base, byte local de inicio), o `null` si [line] no lo es. */
    fun parseLogBase(line: String): LogBase? {
        if (!line.contains(LOG_BASE_EVENT_TYPE)) return null
        val obj = runCatching { Json.parseToJsonElement(line) }.getOrNull().objectOrNull ?: return null
        if (obj["type"].stringOrNull != LOG_BASE_EVENT_TYPE) return null
        val base = integer(obj["base"]) ?: return null
        val from = integer(obj["from"]) ?: return null
        if (base < 0 || from < 1) return null
        return LogBase(base, from)
    }

    /** Número JSON entero (como `as? Int` de Swift: ni cadenas ni decimales). */
    private fun integer(element: kotlinx.serialization.json.JsonElement?): Long? =
        (element as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toLongOrNull()

    /** Base de rotación y byte LOCAL desde el que sigue un enganche. */
    data class LogBase(val base: Long, val from: Long)

    // MARK: Parar / hibernar

    /**
     * Termina el agente (solo si es de verdad el agente): TERM al grupo, espera, KILL. Con
     * [delete], borra su carpeta, pero SOLO si el proceso murió (si no, sale con
     * `ARGOS_AGENT_STUCK` y la carpeta sigue ahí).
     */
    fun stop(id: String, delete: Boolean, graceSeconds: Int = PersistentAgentShell.STOP_GRACE_SECONDS): String {
        val dir = directory(id)
        val terminate = PersistentAgentShell.terminateProcess(id, graceSeconds)
        val kill = "{ if ${aliveCheck(id)}; then $terminate; fi; rm -f $dir/pid; true; }"
        return if (delete) "$kill && rm -rf $dir" else kill
    }

    /**
     * Hiberna a demanda («Hibernar inactivos»), pero solo si EN EL SERVIDOR sigue quieto y sin
     * actividad desde hace [minIdleSeconds]. Imprime `ARGOS_HIBERNATED <id>` si lo hizo.
     */
    fun hibernate(id: String, minIdleSeconds: Int): String = listOf(
        "${aliveCheck(id)} || exit 0",
        PersistentAgentShell.acquireLock(id, 5, "exit 0"),
        "trap '${PersistentAgentShell.releaseLock(id)}' EXIT",
        "h=0",
        PersistentAgentShell.hibernateIfQuiet(id, maxOf(0, minIdleSeconds)),
        "[ \"\$h\" = 1 ] && echo $HIBERNATED_REPLY $id",
        "true",
    ).joinToString("\n")

    /** Final de `err.log` (para explicar por qué el agente no está en marcha). */
    fun errorTail(id: String): String = "tail -c $ERROR_TAIL_BYTES ${directory(id)}/err.log 2>/dev/null; true"

    // MARK: Listado

    /** `$size` += `log.base` de la carpeta `$d` (dentro de los bucles de listado). */
    const val ABSOLUTE_SIZE = "b=\$(cat \"\$d/log.base\" 2>/dev/null); case \"\$b\" in ''|*[!0-9]*) b=0;; esac; size=\$(( \${size:-0} + b ))"

    /** Bucle común de [list] y [snapshots] hasta el meta.json en base64 incluido. */
    private const val LIST_PREFIX = "for d in \"\$HOME/$ROOT_RELATIVE_PATH\"/*/; do " +
        "[ -f \"\$d/meta.json\" ] || continue; " +
        "id=\$(basename \"\$d\"); p=\$(cat \"\$d/pid\" 2>/dev/null); alive=0; " +
        "[ -n \"\$p\" ] && ps -o args= -p \"\$p\" 2>/dev/null | grep -q -- \"\$id\" && alive=1; " +
        "size=\$(wc -c < \"\$d/out.ndjson\" 2>/dev/null | tr -d ' '); " +
        "$ABSOLUTE_SIZE; " +
        "printf '%s|%s|%s|' \"\$id\" \"\$alive\" \"\$size\"; " +
        "base64 < \"\$d/meta.json\" | tr -d '\\n'; "

    /** Una línea por agente: `id|vivo(0/1)|bytes ABSOLUTOS del log|meta.json en base64`. */
    fun list(): String = LIST_PREFIX + "echo; done"

    fun parseList(output: String): List<PersistentAgentInfo> = SwiftText.lines(output).mapNotNull { line ->
        val fields = line.split("|", limit = 4)
        if (fields.size != 4 || !isValidID(fields[0])) return@mapNotNull null
        val meta = decodeMetaBase64(fields[3]) ?: return@mapNotNull null
        PersistentAgentInfo(fields[0], fields[1] == "1", fields[2].toLongOrNull() ?: 0, meta)
    }.sortedByDescending { it.meta.createdAt }

    /**
     * Recorta las últimas líneas del log: si una lleva `tool_name` lejos del principio, se
     * conserva su comienzo (tipo, `request_id`) y ese campo; después se corta a
     * [ATTENTION_LINE_BYTES]. (`.{1,200}`: los `sed` BSD no admiten repeticiones > 255.)
     */
    fun attentionTail(file: String): String =
        "tail -n $ATTENTION_TAIL_LINES $file 2>/dev/null " +
            "| sed -E '/\"tool_name\":\"/ s/^(.{1,200}).*(\"tool_name\":\"[^\"]*\").*\$/\\1 \\2/' " +
            "| cut -c 1-$ATTENTION_LINE_BYTES"

    /** Una línea por agente: `id|vivo|bytes|meta en base64|final recortado en base64`. */
    fun snapshots(): String =
        LIST_PREFIX + "printf '|'; " +
            "${attentionTail("\"\$d/out.ndjson\"")} | base64 | tr -d '\\n'; echo; done"

    fun parseSnapshots(output: String): List<AgentLogSnapshot> = SwiftText.lines(output).mapNotNull { line ->
        val fields = line.split("|", limit = 5)
        if (fields.size != 5 || !isValidID(fields[0])) return@mapNotNull null
        val meta = decodeMetaBase64(fields[3]) ?: return@mapNotNull null
        val tail = SwiftText.decodeBase64(fields[4])?.toString(Charsets.UTF_8) ?: ""
        AgentLogSnapshot(fields[0], fields[1] == "1", fields[2].toLongOrNull() ?: 0, meta.title, meta.createdAt, tail, meta.workingDirectory)
    }

    internal fun decodeMetaBase64(text: String): PersistentAgentMeta? =
        SwiftText.decodeBase64(text)?.let { PersistentAgentMeta.decode(it.toString(Charsets.UTF_8)) }
}
