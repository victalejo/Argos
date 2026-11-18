//
//  PersistentAgentShell.swift
//  Argos
//
//  Trozos de shell POSIX que comparten los comandos del agente persistente: parar con
//  espera y escalado a KILL, hibernar, recortar `err.log`, rotar `out.ndjson` y el
//  vigilante de inactividad. Lógica pura (texto), testeable y portable a Kotlin.
//  Funcionan igual en dash (el `sh` de Debian/Ubuntu), bash y zsh.
//
//  SEGURIDAD: nunca se mata un PID sin comprobar EN ESE INSTANTE que su línea de comandos
//  lleva el id del agente (`isAgent`); al grupo solo se manda la señal si el agente es su
//  propio líder (lo deja así `setsid`) y no es el grupo de quien ejecuta el script.
//
//  COMPATIBILIDAD: todo es ADITIVO sobre la carpeta del agente. Lo nuevo:
//   - `log.base`: bytes que una rotación quitó del principio de `out.ndjson`. El byte k
//     del archivo actual es el byte absoluto `base + k`. Sin archivo, base = 0 (lo de
//     siempre). Las versiones antiguas lo ignoran.
//   - Antes de rotar se anexa al archivo viejo `{"type":"argos_log_rotated"}`: quien esté
//     siguiéndolo con `tail -F` sabe que debe reengancharse. Sus bytes NO cuentan en los
//     desplazamientos absolutos (no se guardan en el archivo nuevo).
//   - `.rotating`: existe mientras se rota (el enganche espera a que desaparezca).
//   - `meta.json` puede llevar `"hibernatedAt"` (fecha ISO 8601): Swift y Kotlin
//     ignoran las claves que no conocen.
//

import Foundation

enum PersistentAgentShell {

    /// `err.log` se recorta a sus últimos `errLogKeepBytes` al pasar de `errLogMaxBytes`.
    static let errLogMaxBytes = 262_144
    static let errLogKeepBytes = 65_536
    /// `out.ndjson` se rota (solo con el agente parado) al pasar de `outLogMaxBytes`,
    /// conservando su final (unos `outLogKeepBytes`, desde una línea completa). Umbral
    /// alto a propósito: las versiones antiguas (Android publicado, iOS viejo) miden el
    /// tamaño LOCAL y, tras rotar, no avisan hasta que el log vuelve a crecer lo quitado.
    static let outLogMaxBytes = 64 * 1_048_576
    static let outLogKeepBytes = 32 * 1_048_576
    /// Segundos que se espera a que el agente muera con TERM antes de mandar KILL.
    static let stopGraceSeconds = 10
    /// Segundos que el lanzador espera al cerrojo (p. ej. mientras el vigilante hiberna).
    static let lockWaitSeconds = 20

    /// Marca que se escribe en stderr si el proceso no muere ni con KILL.
    static let stuckMarker = "ARGOS_AGENT_STUCK"
    /// Línea que se anexa al log viejo antes de rotarlo.
    static let rotatedEventType = "argos_log_rotated"
    static var rotatedLine: String { "{\"type\":\"\(rotatedEventType)\"}" }

    /// Cerrojo compartido por lanzar, hibernar y el vigilante.
    static func lockPath(_ id: String) -> String {
        "\"$HOME/\(PersistentAgentScript.rootRelativePath)/.\(id).lock\""
    }

    /// Coge el cerrojo esperando hasta `waitSeconds`; si no puede, ejecuta `onBusy`.
    static func acquireLock(_ id: String, waitSeconds: Int, onBusy: String) -> String {
        "n=0; until mkdir \(lockPath(id)) 2>/dev/null; do n=$((n+1)); "
            + "if [ $n -ge \(waitSeconds) ]; then \(onBusy); fi; sleep 1; done"
    }

    static func releaseLock(_ id: String) -> String {
        "rmdir \(lockPath(id)) 2>/dev/null"
    }

    /// Base del log (bytes rotados) en `$b`, siempre un entero.
    static func readBase(_ dir: String) -> String {
        "b=$(cat \(dir)/log.base 2>/dev/null); case \"$b\" in ''|*[!0-9]*) b=0;; esac"
    }

    /// Fecha de modificación (epoch) de `file` en `$m`: GNU `stat -c`, BSD `stat -f`.
    static func modificationTime(_ file: String, into variable: String = "m") -> String {
        "\(variable)=$(stat -c %Y \(file) 2>/dev/null || stat -f %m \(file) 2>/dev/null)"
    }

    /// ¿Es `$p` AHORA MISMO el agente `id`? (su línea de comandos lleva el id).
    static func isAgent(_ id: String) -> String {
        "ps -o args= -p \"$p\" 2>/dev/null | grep -q -- '\(id)'"
    }

    /// Destino de las señales en `$t`: el GRUPO (`-$p`) si el agente es su propio líder
    /// y no es el grupo de este script (p. ej. sin `setsid`); si no, solo el proceso.
    static let signalTarget = "g=$(ps -o pgid= -p \"$p\" 2>/dev/null | tr -d ' '); "
        + "me=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' '); "
        + "if [ -n \"$g\" ] && [ \"$g\" = \"$p\" ] && [ \"$g\" != \"$me\" ]; then t=\"-$p\"; else t=\"$p\"; fi"

    /// Para el proceso `$p`: TERM, espera, KILL; cada señal solo si `$p` sigue siendo el
    /// agente. `kill -s SEÑAL -- -PGID` es la forma que aceptan dash, bash y zsh (dash
    /// rechaza `kill -TERM -- -PGID`). Si ni con KILL muere, sale con error SIN tocar nada
    /// más (no se borra una carpeta con el agente vivo).
    static func terminateProcess(id: String, graceSeconds: Int = stopGraceSeconds) -> String {
        let alive = isAgent(id)
        return [
            signalTarget,
            "if \(alive); then kill -s TERM -- \"$t\" 2>/dev/null || kill -s TERM \"$p\" 2>/dev/null; fi",
            "i=0; while \(alive) && [ $i -lt \(graceSeconds) ]; do sleep 1; i=$((i+1)); done",
            "if \(alive); then kill -s KILL -- \"$t\" 2>/dev/null || kill -s KILL \"$p\" 2>/dev/null; sleep 1; fi",
            "if \(alive); then echo \(stuckMarker) >&2; exit 5; fi",
        ].joined(separator: "; ")
    }

    /// Anota en `meta.json` que el agente se hibernó (si no lo estaba ya). `meta.json` es
    /// JSON con sangría cuya última línea es `}`: se añade la clave antes de cerrarlo.
    static func markHibernated(_ dir: String) -> String {
        "if [ -f \(dir)/meta.json ] && ! grep -q '\"hibernatedAt\"' \(dir)/meta.json; then "
            + "t0=$(date -u +%Y-%m-%dT%H:%M:%SZ); "
            + "( umask 077 && sed '$ s/}[[:space:]]*$/,\"hibernatedAt\":\"'\"$t0\"'\"}/' \(dir)/meta.json > \(dir)/meta.json.tmp ) "
            + "&& mv \(dir)/meta.json.tmp \(dir)/meta.json; fi"
    }

    /// Verdadero si `meta.json` dice que está hibernado (o hibernándose).
    static func isMarkedHibernated(_ dir: String) -> String {
        "grep -q '\"hibernatedAt\"' \(dir)/meta.json 2>/dev/null"
    }

    /// Recorta `err.log` en el MISMO archivo (claude lo tiene abierto con `>>`, en modo
    /// anexar: sigue escribiendo al final sin huecos).
    static func trimErrorLog(_ dir: String) -> String {
        "es=$(wc -c < \(dir)/err.log 2>/dev/null | tr -d ' '); "
            + "if [ \"${es:-0}\" -gt \(errLogMaxBytes) ]; then "
            + "tail -c \(errLogKeepBytes) \(dir)/err.log > \(dir)/err.log.tmp && cat \(dir)/err.log.tmp > \(dir)/err.log; "
            + "rm -f \(dir)/err.log.tmp; fi"
    }

    /// Rota `out.ndjson` si es enorme. SOLO con el agente parado (lo llama el lanzador
    /// con el cerrojo cogido): conserva el final desde una línea completa, suma a
    /// `log.base` lo quitado (así los desplazamientos ABSOLUTOS siguen valiendo) y avisa a
    /// quien siga el archivo viejo con la línea `argos_log_rotated`.
    static func rotateOutputLog(_ dir: String, maxBytes: Int = outLogMaxBytes, keepBytes: Int = outLogKeepBytes) -> String {
        let out = "\(dir)/out.ndjson"
        return "os=$(wc -c < \(out) 2>/dev/null | tr -d ' '); "
            + "if [ \"${os:-0}\" -gt \(maxBytes) ]; then "
            + ": > \(dir)/.rotating; \(readBase(dir)); "
            + "tail -c \(keepBytes) \(out) > \(dir)/out.tmp && "
            + "l=$(head -n 1 \(dir)/out.tmp | wc -c | tr -d ' ') && "
            + "tail -c +$((l + 1)) \(dir)/out.tmp > \(dir)/out.new && "
            + "k=$(wc -c < \(dir)/out.new | tr -d ' ') && "
            + "echo $((b + os - k)) > \(dir)/log.base.tmp && "
            + "printf '%s\\n' '\(rotatedLine)' >> \(out) && "
            + "mv \(dir)/log.base.tmp \(dir)/log.base && mv \(dir)/out.new \(out); "
            + "rm -f \(dir)/out.tmp \(dir)/out.new \(dir)/log.base.tmp \(dir)/.rotating; fi"
    }

    /// `$last`: la última línea relevante del log (prompt, respuesta, permiso o fin de
    /// turno). Las cadenas JSON escapan sus comillas, así que `"type":"result"` literal
    /// solo aparece como clave de primer nivel de un evento.
    static func lastSignificantLine(_ dir: String) -> String {
        "last=$(tail -n 200 \(dir)/out.ndjson 2>/dev/null "
            + "| grep -E '\"type\":\"(result|control_request|user|assistant)\"' | tail -n 1)"
    }

    /// ¿Está el agente quieto? (turno terminado o sin conversación, y sin permiso
    /// pendiente). Evalúa a verdadero/falso según `$last`.
    static let isQuiescentTest = "case \"$last\" in ''|*'\"type\":\"result\"'*) true;; *) false;; esac"

    /// Verdadero si el log lleva `minIdleSeconds` sin cambiar y el agente está quieto.
    static func quietTest(_ dir: String, minIdleSeconds: Int) -> String {
        "{ now=$(date +%s); \(modificationTime("\(dir)/out.ndjson")); [ -n \"$m\" ] || m=$now; "
            + "[ $((now - m)) -ge \(minIdleSeconds) ] && { \(lastSignificantLine(dir)); \(isQuiescentTest); }; }"
    }

    /// Segundos de CPU (enteros) del grupo de `$p` (si es su líder) o del propio `$p`, en `$c`.
    static let groupCPU = "c=$(ps -eo pgid=,pid=,time= 2>/dev/null | awk -v p=\"$p\" "
        + "'($1==p || $2==p) { x=$3; d=0; j=index(x,\"-\"); if (j) { d=substr(x,1,j-1); x=substr(x,j+1) } "
        + "n=split(x,a,\":\"); s=0; for (i=1;i<=n;i++) s=s*60+a[i]; t+=d*86400+s } END { printf \"%d\", t }')"

    /// Hiberna si sigue quieto: con el cerrojo, vuelve a comprobar que es el agente, la
    /// inactividad y la quietud; lo anota en `meta.json` y lo para. Requiere `$p`; deja
    /// `h=1` si lo hibernó.
    static func hibernateIfQuiet(id: String, minIdleSeconds: Int) -> String {
        let dir = PersistentAgentScript.directory(id)
        return [
            "if \(isAgent(id)) && \(quietTest(dir, minIdleSeconds: minIdleSeconds)); then",
            markHibernated(dir),
            terminateProcess(id: id),
            // Solo si sigue siendo su pid: un «Reanudar» posterior ya pudo escribir otro.
            "[ \"$(cat \(dir)/pid 2>/dev/null)\" = \"$p\" ] && rm -f \(dir)/pid",
            "h=1",
            "fi",
        ].joined(separator: "\n")
    }

    /// Vigilante de inactividad. Corre aparte (`sh -c` con `$1` = pid del agente) y
    /// termina solo en cuanto ese PID deja de ser el agente (parado, reanudado con otro
    /// pid, muerto o REUTILIZADO por otro proceso). Si el log no cambia en `idleSeconds`,
    /// el agente está quieto y su grupo no gasta CPU, lo hiberna con el cerrojo cogido
    /// (un «Reanudar» o un envío simultáneos esperan o lo ven hibernado).
    static func watchdog(id: String, idleSeconds: Int, checkSeconds: Int) -> String {
        let dir = PersistentAgentScript.directory(id)
        return [
            "p=$1",
            groupCPU + "; c0=$c",
            "while sleep \(checkSeconds); do",
            "[ \"$(cat \(dir)/pid 2>/dev/null)\" = \"$p\" ] || exit 0",
            "\(isAgent(id)) || exit 0",
            trimErrorLog(dir),
            groupCPU + "; busy=$((c - c0)); c0=$c",
            "[ \"$busy\" -lt \(PersistentAgentHibernation.busyCPUSeconds) ] || continue",
            "\(quietTest(dir, minIdleSeconds: idleSeconds)) || continue",
            "mkdir \(lockPath(id)) 2>/dev/null || continue",
            "trap '\(releaseLock(id))' EXIT",
            "h=0",
            hibernateIfQuiet(id: id, minIdleSeconds: idleSeconds),
            releaseLock(id) + "; trap - EXIT",
            "[ \"$h\" = 1 ] && exit 0",
            "done",
        ].joined(separator: "\n")
    }
}
