package com.iaportafolio.argos.core.agent

/**
 * Trozos de shell POSIX que comparten los comandos del agente persistente (port BYTE A BYTE de
 * `ArgosCore/Agent/PersistentAgentShell.swift`): parar con espera y escalado a KILL, hibernar,
 * recortar `err.log`, rotar `out.ndjson` y el vigilante de inactividad. Funcionan igual en dash
 * (el `sh` de Debian/Ubuntu), bash y zsh.
 *
 * SEGURIDAD: nunca se mata un PID sin comprobar EN ESE INSTANTE que su línea de comandos lleva
 * el id del agente ([isAgent]); al grupo solo se manda la señal si el agente es su propio líder
 * (lo deja así `setsid`) y no es el grupo de quien ejecuta el script.
 *
 * COMPATIBILIDAD: todo es ADITIVO sobre la carpeta del agente:
 * - `log.base`: bytes que una rotación quitó del principio de `out.ndjson` (sin archivo, 0).
 * - Marca `{"type":"argos_log_rotated"}`: se anexa al archivo viejo antes de rotarlo Y es la
 *   PRIMERA línea del nuevo. Un `tail -F` enganchado la ve siempre: al final del viejo o, si el
 *   archivo se sustituyó antes de leerla, al reabrir el nuevo (que reenvía desde el principio).
 *   Sus bytes NO cuentan: el cliente deja de contar en ella y se reengancha. La del archivo nuevo
 *   ocupa bytes locales, pero `log.base` se ajusta para que lo conservado siga en su byte absoluto
 *   y `attach` la salta. Las versiones publicadas la ignoran como evento desconocido.
 * - `.rotating`: existe mientras se rota (el enganche espera a que desaparezca).
 * - `meta.json` puede llevar `"hibernatedAt"`: las versiones antiguas lo ignoran.
 */
object PersistentAgentShell {

    /** `err.log` se recorta a sus últimos [ERR_LOG_KEEP_BYTES] al pasar de [ERR_LOG_MAX_BYTES]. */
    const val ERR_LOG_MAX_BYTES = 262_144
    const val ERR_LOG_KEEP_BYTES = 65_536

    /**
     * `out.ndjson` se rota (solo con el agente parado) al pasar de [OUT_LOG_MAX_BYTES],
     * conservando su final. Umbral alto a propósito: las versiones antiguas miden el tamaño
     * LOCAL y, tras rotar, no avisan hasta que el log vuelve a crecer lo quitado.
     */
    const val OUT_LOG_MAX_BYTES = 64 * 1_048_576
    const val OUT_LOG_KEEP_BYTES = 32 * 1_048_576

    /** Segundos que se espera a que el agente muera con TERM antes de mandar KILL. */
    const val STOP_GRACE_SECONDS = 10

    /** Segundos que el lanzador espera al cerrojo (p. ej. mientras el vigilante hiberna). */
    const val LOCK_WAIT_SECONDS = 20

    /** Marca que se escribe en stderr si el proceso no muere ni con KILL. */
    const val STUCK_MARKER = "ARGOS_AGENT_STUCK"

    /** Línea que se anexa al log viejo antes de rotarlo y con la que empieza el nuevo. */
    const val ROTATED_EVENT_TYPE = "argos_log_rotated"
    const val ROTATED_LINE = "{\"type\":\"$ROTATED_EVENT_TYPE\"}"

    /** Bytes de la marca con su salto de línea (lo que ocupa al principio del log nuevo). */
    val ROTATED_LINE_BYTES: Int = ROTATED_LINE.toByteArray(Charsets.UTF_8).size + 1

    /** Cerrojo compartido por lanzar, hibernar y el vigilante. */
    fun lockPath(id: String): String = "\"\$HOME/${PersistentAgentScript.ROOT_RELATIVE_PATH}/.$id.lock\""

    /** Coge el cerrojo esperando hasta [waitSeconds]; si no puede, ejecuta [onBusy]. */
    fun acquireLock(id: String, waitSeconds: Int, onBusy: String): String =
        "n=0; until mkdir ${lockPath(id)} 2>/dev/null; do n=\$((n+1)); " +
            "if [ \$n -ge $waitSeconds ]; then $onBusy; fi; sleep 1; done"

    fun releaseLock(id: String): String = "rmdir ${lockPath(id)} 2>/dev/null"

    /** Un cerrojo de más de un minuto es de un lanzamiento o envío que se interrumpió. */
    fun clearStaleLock(id: String): String =
        "find \"\$HOME/${PersistentAgentScript.ROOT_RELATIVE_PATH}\" -maxdepth 1 -name '.$id.lock' -mmin +1 -exec rmdir {} \\; 2>/dev/null"

    /**
     * Para los ENVÍOS: con el cerrojo del vigilante cogido (y soltándolo al salir), así comprobar
     * que no se hiberna y escribir en la FIFO es atómico respecto a hibernar.
     */
    fun lockForDelivery(id: String, onBusy: String): String =
        "${clearStaleLock(id)}; ${acquireLock(id, LOCK_WAIT_SECONDS, onBusy)}; trap '${releaseLock(id)}' EXIT"

    /**
     * Tras escribir en la FIFO se toca el log: hasta que claude lea la línea el log no cambia, y
     * un vigilante (también los de versiones antiguas, que miran su fecha) lo vería quieto y lo
     * pararía con el mensaje aún sin leer.
     */
    fun touchLog(dir: String): String = "touch $dir/out.ndjson"

    /** Base del log (bytes rotados) en `$b`, siempre un entero. */
    fun readBase(dir: String): String =
        "b=\$(cat $dir/log.base 2>/dev/null); case \"\$b\" in ''|*[!0-9]*) b=0;; esac"

    /** Fecha de modificación (epoch) de [file] en [variable]: GNU `stat -c`, BSD `stat -f`. */
    fun modificationTime(file: String, variable: String = "m"): String =
        "$variable=\$(stat -c %Y $file 2>/dev/null || stat -f %m $file 2>/dev/null)"

    /** ¿Es `$p` AHORA MISMO el agente [id]? (su línea de comandos lleva el id). */
    fun isAgent(id: String): String = "ps -o args= -p \"\$p\" 2>/dev/null | grep -q -- '$id'"

    /**
     * Destino de las señales en `$t`: el GRUPO (`-$p`) si el agente es su propio líder y no es
     * el grupo de este script; si no, solo el proceso.
     */
    const val SIGNAL_TARGET = "g=\$(ps -o pgid= -p \"\$p\" 2>/dev/null | tr -d ' '); " +
        "me=\$(ps -o pgid= -p \$\$ 2>/dev/null | tr -d ' '); " +
        "if [ -n \"\$g\" ] && [ \"\$g\" = \"\$p\" ] && [ \"\$g\" != \"\$me\" ]; then t=\"-\$p\"; else t=\"\$p\"; fi"

    /**
     * Para el proceso `$p`: TERM, espera, KILL; cada señal solo si `$p` sigue siendo el agente.
     * `kill -s SEÑAL -- -PGID` es la forma que aceptan dash, bash y zsh. Si ni con KILL muere,
     * sale con error SIN tocar nada más.
     */
    fun terminateProcess(id: String, graceSeconds: Int = STOP_GRACE_SECONDS): String {
        val alive = isAgent(id)
        return listOf(
            SIGNAL_TARGET,
            "if $alive; then kill -s TERM -- \"\$t\" 2>/dev/null || kill -s TERM \"\$p\" 2>/dev/null; fi",
            "i=0; while $alive && [ \$i -lt $graceSeconds ]; do sleep 1; i=\$((i+1)); done",
            "if $alive; then kill -s KILL -- \"\$t\" 2>/dev/null || kill -s KILL \"\$p\" 2>/dev/null; sleep 1; fi",
            "if $alive; then echo $STUCK_MARKER >&2; exit 5; fi",
        ).joinToString("; ")
    }

    /** Anota en `meta.json` que el agente se hibernó (si no lo estaba ya). */
    fun markHibernated(dir: String): String =
        "if [ -f $dir/meta.json ] && ! grep -q '\"hibernatedAt\"' $dir/meta.json; then " +
            "t0=\$(date -u +%Y-%m-%dT%H:%M:%SZ); " +
            "( umask 077 && sed '\$ s/}[[:space:]]*\$/,\"hibernatedAt\":\"'\"\$t0\"'\"}/' $dir/meta.json > $dir/meta.json.tmp ) " +
            "&& mv $dir/meta.json.tmp $dir/meta.json; fi"

    /** Verdadero si `meta.json` dice que está hibernado (o hibernándose). */
    fun isMarkedHibernated(dir: String): String = "grep -q '\"hibernatedAt\"' $dir/meta.json 2>/dev/null"

    /** Recorta `err.log` en el MISMO archivo (claude lo tiene abierto en modo anexar). */
    fun trimErrorLog(dir: String): String =
        "es=\$(wc -c < $dir/err.log 2>/dev/null | tr -d ' '); " +
            "if [ \"\${es:-0}\" -gt $ERR_LOG_MAX_BYTES ]; then " +
            "tail -c $ERR_LOG_KEEP_BYTES $dir/err.log > $dir/err.log.tmp && cat $dir/err.log.tmp > $dir/err.log; " +
            "rm -f $dir/err.log.tmp; fi"

    /**
     * Rota `out.ndjson` si es enorme. SOLO con el agente parado (lo llama el lanzador con el
     * cerrojo cogido): conserva el final desde una línea completa, EMPIEZA el archivo nuevo por la
     * marca `argos_log_rotated` (también la anexa al viejo) y deja en `log.base` lo quitado menos
     * lo que ocupa la marca: lo conservado sigue en su byte ABSOLUTO.
     */
    fun rotateOutputLog(dir: String, maxBytes: Int = OUT_LOG_MAX_BYTES, keepBytes: Int = OUT_LOG_KEEP_BYTES): String {
        val out = "$dir/out.ndjson"
        return "os=\$(wc -c < $out 2>/dev/null | tr -d ' '); " +
            "if [ \"\${os:-0}\" -gt $maxBytes ]; then " +
            ": > $dir/.rotating; ${readBase(dir)}; " +
            "tail -c $keepBytes $out > $dir/out.tmp && " +
            "l=\$(head -n 1 $dir/out.tmp | wc -c | tr -d ' ') && " +
            "{ printf '%s\\n' '$ROTATED_LINE' && tail -c +\$((l + 1)) $dir/out.tmp; } > $dir/out.new && " +
            "k=\$(wc -c < $dir/out.new | tr -d ' ') && [ \$((b + os - k)) -ge 0 ] && " +
            "echo \$((b + os - k)) > $dir/log.base.tmp && " +
            "printf '%s\\n' '$ROTATED_LINE' >> $out && " +
            "mv $dir/log.base.tmp $dir/log.base && mv $dir/out.new $out; " +
            "rm -f $dir/out.tmp $dir/out.new $dir/log.base.tmp $dir/.rotating; fi"
    }

    /** `$last`: la última línea relevante del log (prompt, respuesta, permiso o fin de turno). */
    fun lastSignificantLine(dir: String): String =
        "last=\$(tail -n 200 $dir/out.ndjson 2>/dev/null " +
            "| grep -E '\"type\":\"(result|control_request|user|assistant)\"' | tail -n 1)"

    /** ¿Está quieto? (turno terminado o sin conversación, y sin permiso pendiente). */
    const val IS_QUIESCENT_TEST = "case \"\$last\" in ''|*'\"type\":\"result\"'*) true;; *) false;; esac"

    /** Verdadero si el log lleva [minIdleSeconds] sin cambiar y el agente está quieto. */
    fun quietTest(dir: String, minIdleSeconds: Int): String =
        "{ now=\$(date +%s); ${modificationTime("$dir/out.ndjson")}; [ -n \"\$m\" ] || m=\$now; " +
            "[ \$((now - m)) -ge $minIdleSeconds ] && { ${lastSignificantLine(dir)}; $IS_QUIESCENT_TEST; }; }"

    /** Segundos de CPU (enteros) del grupo de `$p` (si es su líder) o del propio `$p`, en `$c`. */
    const val GROUP_CPU = "c=\$(ps -eo pgid=,pid=,time= 2>/dev/null | awk -v p=\"\$p\" " +
        "'(\$1==p || \$2==p) { x=\$3; d=0; j=index(x,\"-\"); if (j) { d=substr(x,1,j-1); x=substr(x,j+1) } " +
        "n=split(x,a,\":\"); s=0; for (i=1;i<=n;i++) s=s*60+a[i]; t+=d*86400+s } END { printf \"%d\", t }')"

    /**
     * Hiberna si sigue quieto: con el cerrojo, vuelve a comprobar que es el agente, la
     * inactividad y la quietud; lo anota en `meta.json` y lo para. Requiere `$p`; deja `h=1`.
     */
    fun hibernateIfQuiet(id: String, minIdleSeconds: Int): String {
        val dir = PersistentAgentScript.directory(id)
        return listOf(
            "if ${isAgent(id)} && ${quietTest(dir, minIdleSeconds)}; then",
            markHibernated(dir),
            terminateProcess(id),
            // Solo si sigue siendo su pid: un «Reanudar» posterior ya pudo escribir otro.
            "[ \"\$(cat $dir/pid 2>/dev/null)\" = \"\$p\" ] && rm -f $dir/pid",
            "h=1",
            "fi",
        ).joinToString("\n")
    }

    /**
     * Vigilante de inactividad. Corre aparte (`sh -c` con `$1` = pid del agente) y termina en
     * cuanto ese PID deja de ser el agente. Si el log no cambia en [idleSeconds], el agente está
     * quieto y su grupo no gasta CPU, lo hiberna con el cerrojo cogido.
     */
    fun watchdog(id: String, idleSeconds: Int, checkSeconds: Int): String {
        val dir = PersistentAgentScript.directory(id)
        return listOf(
            "p=\$1",
            "$GROUP_CPU; c0=\$c",
            "while sleep $checkSeconds; do",
            "[ \"\$(cat $dir/pid 2>/dev/null)\" = \"\$p\" ] || exit 0",
            "${isAgent(id)} || exit 0",
            trimErrorLog(dir),
            "$GROUP_CPU; busy=\$((c - c0)); c0=\$c",
            "[ \"\$busy\" -lt ${PersistentAgentHibernation.BUSY_CPU_SECONDS} ] || continue",
            "${quietTest(dir, idleSeconds)} || continue",
            "mkdir ${lockPath(id)} 2>/dev/null || continue",
            "trap '${releaseLock(id)}' EXIT",
            "h=0",
            hibernateIfQuiet(id, idleSeconds),
            "${releaseLock(id)}; trap - EXIT",
            "[ \"\$h\" = 1 ] && exit 0",
            "done",
        ).joinToString("\n")
    }
}
