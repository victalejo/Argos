package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.SSHServicing

/** Un agente de Argos vivo (o parado, si es persistente) en el servidor. */
data class ServerAgentProcess(
    /** Id de sesión de Claude (UUID en minúsculas). */
    val sessionID: String,
    val kind: Kind,
    val isAlive: Boolean,
    /** Memoria residente (KB); 0 si está parado o no se sabe. */
    val residentKB: Long,
    /** Segundos desde la última escritura en su log (`null` en los del panel: no tienen). */
    val idleSeconds: Long?,
    /** Hay un permiso sin responder (solo persistentes). */
    val hasPendingPermission: Boolean,
) {
    sealed interface Kind {
        /** Agente persistente (iPhone/iPad/Android): se para por su carpeta. */
        data class Persistent(val meta: PersistentAgentMeta) : Kind

        /** Conversación del panel Agente del Mac: se para por PID. */
        data class Panel(val pid: Int) : Kind
    }

    val id: String get() = sessionID

    val title: String
        get() = when (kind) {
            is Kind.Persistent -> kind.meta.title
            is Kind.Panel -> "Conversación del Mac"
        }
}

/**
 * TODOS los agentes de Argos vivos en un servidor, de cualquier proyecto (port de
 * `ArgosCore/Agent/ServerAgentInventory.swift`): los persistentes y los del panel Agente del Mac
 * (`claude -p --input-format stream-json` SIN `--replay-user-messages`), con su memoria
 * residente e inactividad. Un solo comando; el análisis es puro.
 *
 * Nunca aparece un `claude` interactivo (tmux) ni uno ajeno a Argos: se exige la forma exacta de
 * la invocación headless de Argos y un id de sesión UUID.
 */
data class ServerAgentInventory(
    val agents: List<ServerAgentProcess>,
    /** `MemAvailable` del servidor (KB), si es Linux. */
    val freeMemoryKB: Long?,
) {
    val liveAgents: List<ServerAgentProcess> get() = agents.filter { it.isAlive }
    val liveResidentKB: Long get() = liveAgents.sumOf { it.residentKB }

    /**
     * Persistentes vivos, quietos (sin permiso pendiente) y sin actividad desde hace al menos
     * [idleSeconds]: los que «Hibernar inactivos» puede parar sin perder nada.
     */
    fun hibernationCandidates(idleSeconds: Long): List<ServerAgentProcess> = agents.filter { agent ->
        val idle = agent.idleSeconds
        agent.isAlive && !agent.hasPendingPermission && agent.kind is ServerAgentProcess.Kind.Persistent &&
            idle != null && idle >= idleSeconds
    }

    companion object {
        /** Marca que imprime una acción por cada agente que no pudo parar o hibernar. */
        const val FAILED_MARKER = "ARGOS_ACTION_FAILED"

        private val SHELL_PROGRAMS = setOf("sh", "bash", "zsh", "dash", "grep", "sed")

        /**
         * Una línea por agente persistente:
         * `P|id|vivo|rss KB|segundos inactivo|bytes|permiso pendiente(0/1)|meta en base64`; una por
         * proceso headless de claude: `M|pid|rss KB|línea de comandos`; y `MEM|KB disponibles`. El
         * patrón `stream-[j]son` evita que el propio comando se encuentre a sí mismo.
         */
        fun script(): String {
            val root = "\$HOME/${PersistentAgentScript.ROOT_RELATIVE_PATH}"
            val persistent = "now=\$(date +%s); " +
                "for d in \"$root\"/*/; do " +
                "[ -f \"\$d/meta.json\" ] || continue; " +
                "id=\$(basename \"\$d\"); p=\$(cat \"\$d/pid\" 2>/dev/null); alive=0; rss=0; " +
                "if [ -n \"\$p\" ] && ps -o args= -p \"\$p\" 2>/dev/null | grep -q -- \"\$id\"; then alive=1; " +
                "rss=\$(ps -o rss= -p \"\$p\" 2>/dev/null | tr -d ' '); fi; " +
                "${PersistentAgentShell.modificationTime("\"\$d/out.ndjson\"")}; idle=\$(( now - \${m:-\$now} )); " +
                "size=\$(wc -c < \"\$d/out.ndjson\" 2>/dev/null | tr -d ' '); " +
                "${PersistentAgentScript.ABSOLUTE_SIZE}; " +
                "${PersistentAgentShell.lastSignificantLine("\"\$d\"")}; pend=0; " +
                "case \"\$last\" in *'\"type\":\"control_request\"'*) pend=1;; esac; " +
                "printf 'P|%s|%s|%s|%s|%s|%s|' \"\$id\" \"\$alive\" \"\${rss:-0}\" \"\$idle\" \"\$size\" \"\$pend\"; " +
                "base64 < \"\$d/meta.json\" | tr -d '\\n'; echo; " +
                "done"
            val headless = "ps -eo pid=,rss=,args= 2>/dev/null | grep -- 'stream-[j]son' | " +
                "sed 's/^ *//; s/^/M|/; s/  */|/; s/  */|/'"
            val memory = "printf 'MEM|%s\\n' \"\$(awk '/^MemAvailable:/ {print \$2}' /proc/meminfo 2>/dev/null)\""
            return listOf(persistent, headless, memory, "true").joinToString("\n")
        }

        fun parse(output: String): ServerAgentInventory {
            val agents = mutableListOf<ServerAgentProcess>()
            var freeMemory: Long? = null
            for (line in SwiftText.lines(output)) {
                when {
                    line.startsWith("MEM|") -> freeMemory = SwiftText.trimWhitespace(line.substring(4)).toLongOrNull()
                    line.startsWith("P|") -> parsePersistent(line)?.let(agents::add)
                    line.startsWith("M|") -> parsePanel(line)?.let(agents::add)
                }
            }
            val sorted = agents.sortedWith(compareByDescending<ServerAgentProcess> { it.isAlive }.thenByDescending { it.residentKB })
            return ServerAgentInventory(sorted, freeMemory)
        }

        private fun parsePersistent(line: String): ServerAgentProcess? {
            val fields = line.split("|", limit = 8)
            if (fields.size != 8 || !PersistentAgentScript.isValidID(fields[1])) return null
            val meta = PersistentAgentScript.decodeMetaBase64(fields[7]) ?: return null
            val alive = fields[2] == "1"
            return ServerAgentProcess(
                sessionID = fields[1].lowercase(),
                kind = ServerAgentProcess.Kind.Persistent(meta),
                isAlive = alive,
                residentKB = if (alive) fields[3].toLongOrNull() ?: 0 else 0,
                idleSeconds = fields[4].toLongOrNull()?.let { maxOf(0, it) },
                hasPendingPermission = fields[6] == "1",
            )
        }

        private fun parsePanel(line: String): ServerAgentProcess? {
            val fields = line.split("|", limit = 4)
            if (fields.size != 4) return null
            val pid = fields[1].toIntOrNull()?.takeIf { it > 1 } ?: return null
            val sessionID = panelSessionID(fields[3]) ?: return null
            return ServerAgentProcess(
                sessionID = sessionID,
                kind = ServerAgentProcess.Kind.Panel(pid),
                isAlive = true,
                residentKB = fields[2].toLongOrNull() ?: 0,
                idleSeconds = null,
                hasPendingPermission = false,
            )
        }

        /**
         * Id de sesión si [arguments] es EXACTAMENTE una conversación del panel del Mac
         * (`claude -p --input-format stream-json --output-format stream-json … --session-id <uuid>`
         * o `--resume <uuid>`, sin `--replay-user-messages`). Cualquier otra cosa → `null`.
         */
        fun panelSessionID(arguments: String): String? {
            val tokens = arguments.split(" ").filter { it.isNotEmpty() }
            val program = tokens.firstOrNull { !it.startsWith("-") } ?: return null
            val valid = program.substringAfterLast('/') !in SHELL_PROGRAMS &&
                "-p" in tokens &&
                hasPair(tokens, "--input-format", "stream-json") &&
                hasPair(tokens, "--output-format", "stream-json") &&
                hasPair(tokens, "--permission-prompt-tool", "stdio") &&
                "--replay-user-messages" !in tokens
            if (!valid) return null
            for (flag in listOf("--session-id", "--resume")) {
                val index = tokens.indexOf(flag)
                val value = tokens.getOrNull(index + 1)
                if (index >= 0 && value != null && PersistentAgentScript.isValidID(value)) return value.lowercase()
            }
            return null
        }

        private fun hasPair(tokens: List<String>, flag: String, value: String): Boolean {
            val index = tokens.indexOf(flag)
            return index >= 0 && tokens.getOrNull(index + 1) == value
        }

        // MARK: Acciones

        /**
         * Para varios persistentes (sin borrar nada: se pueden reanudar). Cada parada va en su
         * propio subshell: uno atascado no impide parar los demás, y queda anotado.
         */
        fun stopPersistent(ids: List<String>): String = ids.filter(PersistentAgentScript::isValidID)
            .joinToString("\n") { "( ${PersistentAgentScript.stop(it, delete = false)} ) || echo $FAILED_MARKER $it" } + "\ntrue"

        /** Hiberna varios persistentes si EN EL SERVIDOR siguen quietos desde hace [minIdleSeconds]. */
        fun hibernate(ids: List<String>, minIdleSeconds: Int): String = ids.filter(PersistentAgentScript::isValidID)
            .joinToString("\n") { "( ${PersistentAgentScript.hibernate(it, minIdleSeconds)} ) || echo $FAILED_MARKER $it" } + "\ntrue"

        /** Ids que una acción no pudo completar (ver [FAILED_MARKER]). */
        fun failures(output: String): List<String> = SwiftText.lines(output).mapNotNull { line ->
            val parts = line.split(" ").filter { it.isNotEmpty() }
            if (parts.size == 2 && parts[0] == FAILED_MARKER) parts[1] else null
        }

        /**
         * Función de shell `pm PID ID`: verdadero si EN ESTE INSTANTE el PID es una conversación del
         * panel con ese id (no un shell, `grep` u otro programa que lleve el texto, ni un persistente).
         */
        const val PANEL_MATCH_FUNCTION = "pm() { c=\$(ps -o comm= -p \"\$1\" 2>/dev/null); " +
            "case \"\${c##*/}\" in ''|sh|bash|dash|zsh|ksh|fish|grep|sed|awk|ps|ssh|sshd|tail|cat) return 1;; esac; " +
            "a=\$(ps -o args= -p \"\$1\" 2>/dev/null); " +
            "case \"\$a\" in *--replay-user-messages*) return 1;; *'--input-format stream-json'*) ;; *) return 1;; esac; " +
            "printf '%s\\n' \"\$a\" | grep -qi -- \"\$2\"; }"

        /** TERM a las entradas `pid:id` de `$K` que sigan siendo suyas, espera hasta 5 s y KILL. */
        private val TERMINATE_PANEL_ENTRIES = listOf(
            "for e in \$K; do pm \"\${e%%:*}\" \"\${e#*:}\" && kill -s TERM \"\${e%%:*}\" 2>/dev/null; done",
            "i=0; while [ -n \"\$K\" ] && [ \$i -lt 10 ]; do v=0; for e in \$K; do pm \"\${e%%:*}\" \"\${e#*:}\" && v=1; done; " +
                "[ \$v = 0 ] && break; sleep 0.5; i=\$((i+1)); done",
            "for e in \$K; do pm \"\${e%%:*}\" \"\${e#*:}\" && kill -s KILL \"\${e%%:*}\" 2>/dev/null; done",
            "true",
        )

        /** Mata conversaciones del panel por PID, comprobando en cada señal que sigue siendo esa. */
        fun stopPanel(processes: List<Pair<Int, String>>): String {
            val valid = processes.filter { (pid, session) -> pid > 1 && PersistentAgentScript.isValidID(session) }
            if (valid.isEmpty()) return "true"
            val entries = valid.joinToString(" ") { (pid, session) -> "$pid:${session.lowercase()}" }
            return (
                listOf(PANEL_MATCH_FUNCTION, "K=", "for e in $entries; do pm \"\${e%%:*}\" \"\${e#*:}\" && K=\"\$K \$e\"; done") +
                    TERMINATE_PANEL_ENTRIES
                ).joinToString("\n")
        }

        /** Mata TODAS las conversaciones del panel con esos ids, encontrándolas por su línea de comandos. */
        fun stopPanelSessions(sessionIDs: List<String>): String {
            val ids = sessionIDs.map { it.lowercase() }.filter(PersistentAgentScript::isValidID)
            if (ids.isEmpty()) return "true"
            val find = ids.map { id ->
                "for x in \$(ps -eo pid=,args= 2>/dev/null | grep -i -- '$id' | awk '{print \$1}'); do " +
                    "pm \"\$x\" '$id' && K=\"\$K \$x:$id\"; done"
            }
            return (listOf(PANEL_MATCH_FUNCTION, "K=") + find + TERMINATE_PANEL_ENTRIES).joinToString("\n")
        }
    }
}

/** Lee el inventario de agentes del servidor (un viaje SSH). */
suspend fun SSHServicing.serverAgentInventory(): ServerAgentInventory =
    ServerAgentInventory.parse(runAgentScript(ServerAgentInventory.script()))
