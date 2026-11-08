package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.ShellQuoting
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/** Un agente persistente tal como lo lista el servidor. */
data class PersistentAgentInfo(
    val id: String,
    val isAlive: Boolean,
    val logBytes: Long,
    val meta: PersistentAgentMeta,
)

/** `meta.json` de un agente persistente (carpeta, título y fecha de creación). */
data class PersistentAgentMeta(
    val workingDirectory: String,
    val title: String,
    val createdAt: Instant,
) {
    companion object {
        private val ISO_PATTERN = Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})""")
        private val ISO_WRITER = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)

        /**
         * JSON idéntico al de `JSONEncoder.projects` de Swift (pretty, claves ordenadas, sin
         * escapar `/`, fecha ISO 8601 en UTC sin fracciones de segundo).
         */
        fun encode(meta: PersistentAgentMeta): String = SwiftJson.pretty(
            JsonObject(
                mapOf(
                    "workingDirectory" to JsonPrimitive(meta.workingDirectory),
                    "title" to JsonPrimitive(meta.title),
                    "createdAt" to JsonPrimitive(ISO_WRITER.format(meta.createdAt.truncatedTo(ChronoUnit.SECONDS))),
                ),
            ),
            escapeSlashes = false,
            numbers = SwiftJson.Numbers.SHORTEST,
        )

        /** Decodifica como `JSONDecoder.projects`: los tres campos obligatorios; si no, `null`. */
        fun decode(json: String): PersistentAgentMeta? {
            val obj = runCatching { Json.parseToJsonElement(json) }.getOrNull().objectOrNull ?: return null
            val workingDirectory = obj["workingDirectory"].stringOrNull ?: return null
            val title = obj["title"].stringOrNull ?: return null
            val createdAt = obj["createdAt"].stringOrNull?.let(::parseDate) ?: return null
            return PersistentAgentMeta(workingDirectory, title, createdAt)
        }

        private fun parseDate(text: String): Instant? {
            if (!ISO_PATTERN.matches(text)) return null
            return runCatching { OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant() }.getOrNull()
        }
    }
}

/** Respuesta del lanzador ([PersistentAgentScript.launch]) según su primera línea. */
enum class PersistentAgentLaunchReply {
    /** Arrancó (imprimió su PID) o ya estaba vivo (`ARGOS_AGENT_ALIVE`). */
    RUNNING,

    /** Otro dispositivo lo está arrancando ahora mismo (`ARGOS_AGENT_BUSY`). */
    BUSY,

    /** Cualquier otra cosa: no se pudo arrancar. */
    FAILED,
}

/**
 * Agente PERSISTENTE en el servidor (port de `ArgosCore/Agent/PersistentAgentScript.swift`):
 * `claude` corre desacoplado de la conexión SSH y sigue trabajando aunque el móvil se
 * bloquee o cambie de red.
 *
 * Cada agente vive en `~/.config/argos/agents/<id>/` (id = session id de Claude):
 * - `in`: FIFO por la que se le escribe; claude la abre en lectura-escritura (`0<>`).
 * - `out.ndjson`: todo lo que emite claude + una marca por cada permiso respondido.
 * - `pid`, `meta.json`, `err.log`.
 *
 * Aquí solo se construyen los comandos de shell, BYTE A BYTE iguales a los de Swift.
 */
object PersistentAgentScript {

    const val ROOT_RELATIVE_PATH = ".config/argos/agents"

    /** Marca que Argos anexa al log al responder un permiso. */
    const val ANSWERED_EVENT_TYPE = "argos_permission_answered"

    /** Bytes del final del log que bastan para saber el estado (avisos). */
    const val ATTENTION_TAIL_BYTES = 16_384

    private val UUID_PATTERN = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    /** Los ids son UUID (`UUID(uuidString:)`): nada más debe llegar al shell. */
    fun isValidID(id: String): Boolean = UUID_PATTERN.matches(id)

    /**
     * `"$HOME/.config/argos/agents/<id>"` (entre comillas dobles: `$HOME` se expande).
     *
     * @throws IllegalArgumentException si [id] no es un UUID (error de programación; en
     *   Swift es un `precondition`).
     */
    fun directory(id: String): String {
        require(isValidID(id)) { "id de agente no válido" }
        return "\"\$HOME/$ROOT_RELATIVE_PATH/$id\""
    }

    /**
     * Comprueba que el `pid` guardado es DE VERDAD este agente (tras un reinicio ese número
     * puede ser de otro proceso): la línea de comandos de claude lleva el id.
     */
    private fun aliveCheck(id: String): String {
        val dir = directory(id)
        return "{ p=\$(cat $dir/pid 2>/dev/null); [ -n \"\$p\" ] && ps -o args= -p \"\$p\" 2>/dev/null | grep -q -- '$id'; }"
    }

    // MARK: Comandos

    /**
     * Arranca el agente (o lo REANUDA) en segundo plano e imprime su PID; si ya está vivo
     * imprime `ARGOS_AGENT_ALIVE`, y `ARGOS_AGENT_BUSY` si otro lanzamiento tiene el cerrojo.
     *
     * La PRIMERA línea de stdin es el token OAuth (o vacía). [claudeInvocation] es
     * `env … claude <flags>` (ver [ClaudeAgentCommand.persistent]).
     */
    fun launch(id: String, meta: PersistentAgentMeta, claudeInvocation: String): String {
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
            "{ nohup \$S sh -c ${ShellQuoting.singleQuoted(inner)} >/dev/null 2>&1 < /dev/null & echo \$! > $dir/pid; } && cat $dir/pid"
        // `mkdir` como cerrojo atómico: dos «Reanudar» a la vez no lanzan dos claude.
        val lock = "\"\$HOME/$ROOT_RELATIVE_PATH/.$id.lock\""
        return listOf(
            "IFS= read -r ARGOS_OAUTH; export ARGOS_OAUTH",
            "mkdir -p \"\$HOME/$ROOT_RELATIVE_PATH\" && chmod 700 \"\$HOME/$ROOT_RELATIVE_PATH\"",
            // Un cerrojo de más de un minuto es de un lanzamiento que se interrumpió.
            "find \"\$HOME/$ROOT_RELATIVE_PATH\" -maxdepth 1 -name '.$id.lock' -mmin +1 -exec rmdir {} \\; 2>/dev/null",
            "mkdir $lock 2>/dev/null || { echo ARGOS_AGENT_BUSY; exit 4; }",
            "trap 'rmdir $lock 2>/dev/null' EXIT",
            "if ${aliveCheck(id)}; then echo ARGOS_AGENT_ALIVE; exit 0; fi",
            "$prepare && $spawn",
        ).joinToString("\n")
    }

    /** Interpreta la salida del lanzador (como `PersistentAgentSession.start` en Swift). */
    fun parseLaunchReply(reply: String): PersistentAgentLaunchReply {
        val firstLine = SwiftText.lines(reply).firstOrNull() ?: ""
        return when {
            firstLine == "ARGOS_AGENT_BUSY" -> PersistentAgentLaunchReply.BUSY
            firstLine == "ARGOS_AGENT_ALIVE" || firstLine.toIntOrNull() != null -> PersistentAgentLaunchReply.RUNNING
            else -> PersistentAgentLaunchReply.FAILED
        }
    }

    /**
     * Escribe una línea NDJSON en la FIFO del agente, en base64 (nunca se interpreta en el
     * shell). Con [answeredRequestID] (respuesta a un permiso), DESPUÉS de entregarla se
     * anota en el log que ya se respondió.
     */
    fun send(id: String, line: String, answeredRequestID: String? = null): String {
        val dir = directory(id)
        val b64 = SwiftText.encodeBase64("$line\n".toByteArray(Charsets.UTF_8))
        val command = "${aliveCheck(id)} || { echo 'ARGOS_AGENT_DEAD' >&2; exit 3; }; " +
            "exec 3<>$dir/in && printf '%s' '$b64' | base64 -d >&3"
        if (answeredRequestID == null) return command
        // Igual que `JSONSerialization` con `.sortedKeys` (escapa `/`).
        val marker = SwiftJson.compact(
            JsonObject(mapOf("type" to JsonPrimitive(ANSWERED_EVENT_TYPE), "request_id" to JsonPrimitive(answeredRequestID))),
            escapeSlashes = true,
            numbers = SwiftJson.Numbers.PRINTF_17G,
        )
        val markerB64 = SwiftText.encodeBase64("$marker\n".toByteArray(Charsets.UTF_8))
        return "$command && printf '%s' '$markerB64' | base64 -d >> $dir/out.ndjson"
    }

    /**
     * Sigue el log desde el byte [fromByte] (1 = desde el principio). El `tail` muere al
     * cerrarse el canal SSH (EOF en stdin), sin dejar huérfanos.
     */
    fun attach(id: String, fromByte: Long = 1): String =
        "tail -c +${maxOf(1L, fromByte)} -F ${directory(id)}/out.ndjson 2>/dev/null & T=\$!; " +
            "trap 'kill \$T 2>/dev/null' EXIT HUP TERM; cat > /dev/null; kill \$T 2>/dev/null"

    /** Termina el proceso del agente (solo si es de verdad el agente); con [delete] borra su carpeta. */
    fun stop(id: String, delete: Boolean): String {
        val dir = directory(id)
        val kill = "{ if ${aliveCheck(id)}; then kill \"\$p\"; fi; rm -f $dir/pid; true; }"
        return if (delete) "$kill; rm -rf $dir" else kill
    }

    /** Bucle común de [list] y [snapshots] hasta el meta.json en base64 incluido. */
    private const val LIST_PREFIX = "for d in \"\$HOME/$ROOT_RELATIVE_PATH\"/*/; do " +
        "[ -f \"\$d/meta.json\" ] || continue; " +
        "id=\$(basename \"\$d\"); p=\$(cat \"\$d/pid\" 2>/dev/null); alive=0; " +
        "[ -n \"\$p\" ] && ps -o args= -p \"\$p\" 2>/dev/null | grep -q -- \"\$id\" && alive=1; " +
        "size=\$(wc -c < \"\$d/out.ndjson\" 2>/dev/null | tr -d ' '); " +
        "printf '%s|%s|%s|' \"\$id\" \"\$alive\" \"\${size:-0}\"; " +
        "base64 < \"\$d/meta.json\" | tr -d '\\n'; "

    /** Una línea por agente: `id|vivo(0/1)|bytes del log|meta.json en base64`. */
    fun list(): String = LIST_PREFIX + "echo; done"

    fun parseList(output: String): List<PersistentAgentInfo> = SwiftText.lines(output).mapNotNull { line ->
        val fields = line.split("|", limit = 4)
        if (fields.size != 4 || !isValidID(fields[0])) return@mapNotNull null
        val meta = decodeMetaBase64(fields[3]) ?: return@mapNotNull null
        PersistentAgentInfo(fields[0], fields[1] == "1", fields[2].toLongOrNull() ?: 0, meta)
    }.sortedByDescending { it.meta.createdAt }

    /** Una línea por agente: `id|vivo|bytes|meta.json en base64|final del log en base64`. */
    fun snapshots(): String =
        LIST_PREFIX + "printf '|'; " +
            "tail -c $ATTENTION_TAIL_BYTES \"\$d/out.ndjson\" 2>/dev/null | base64 | tr -d '\\n'; echo; done"

    fun parseSnapshots(output: String): List<AgentLogSnapshot> = SwiftText.lines(output).mapNotNull { line ->
        val fields = line.split("|", limit = 5)
        if (fields.size != 5 || !isValidID(fields[0])) return@mapNotNull null
        val meta = decodeMetaBase64(fields[3]) ?: return@mapNotNull null
        val tail = SwiftText.decodeBase64(fields[4])?.toString(Charsets.UTF_8) ?: ""
        AgentLogSnapshot(fields[0], fields[1] == "1", fields[2].toLongOrNull() ?: 0, meta.title, meta.createdAt, tail)
    }

    private fun decodeMetaBase64(text: String): PersistentAgentMeta? =
        SwiftText.decodeBase64(text)?.let { PersistentAgentMeta.decode(it.toString(Charsets.UTF_8)) }
}
