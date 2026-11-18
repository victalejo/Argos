//
//  PersistentAgentShell.swift
//  Argos
//
//  Trozos de shell POSIX que comparten los comandos del agente persistente: parar con
//  espera y escalado a KILL, hibernar, recortar `err.log`, rotar `out.ndjson` y el
//  vigilante de inactividad. Lógica pura (texto), testeable y portable a Kotlin.
//
//  COMPATIBILIDAD: todo es ADITIVO sobre la carpeta del agente. Lo nuevo:
//   - `log.base`: bytes que una rotación quitó del principio de `out.ndjson`. El byte k
//     del archivo actual es el byte absoluto `base + k`. Sin archivo, base = 0 (lo de
//     siempre). Las versiones antiguas lo ignoran.
//   - `meta.json` puede llevar `"hibernatedAt"` (fecha ISO 8601): Swift y Kotlin
//     ignoran las claves que no conocen.
//

import Foundation

enum PersistentAgentShell {

    /// `err.log` se recorta a sus últimos `errLogKeepBytes` al pasar de `errLogMaxBytes`.
    static let errLogMaxBytes = 262_144
    static let errLogKeepBytes = 65_536
    /// `out.ndjson` se rota (solo con el agente parado) al pasar de `outLogMaxBytes`,
    /// conservando su final (unos `outLogKeepBytes`, desde una línea completa).
    static let outLogMaxBytes = 16 * 1_048_576
    static let outLogKeepBytes = 4 * 1_048_576
    /// Segundos que se espera a que el agente muera con TERM antes de mandar KILL.
    static let stopGraceSeconds = 10

    /// Marca que se escribe en stderr si el proceso no muere ni con KILL.
    static let stuckMarker = "ARGOS_AGENT_STUCK"

    /// Base del log (bytes rotados) en `$b`, siempre un entero.
    static func readBase(_ dir: String) -> String {
        "b=$(cat \(dir)/log.base 2>/dev/null); case \"$b\" in ''|*[!0-9]*) b=0;; esac"
    }

    /// Fecha de modificación (epoch) de `file` en `$m`: GNU `stat -c`, BSD `stat -f`.
    static func modificationTime(_ file: String, into variable: String = "m") -> String {
        "\(variable)=$(stat -c %Y \(file) 2>/dev/null || stat -f %m \(file) 2>/dev/null)"
    }

    /// Para el proceso `$p` (ya comprobado que es el agente): TERM al GRUPO (con `setsid`
    /// claude es líder de su grupo y así caen también sus hijos: Bash, servidores MCP…;
    /// sin `setsid`, solo al proceso), espera, escala a KILL y, si ni así muere, sale con
    /// error SIN tocar nada más (no se borra una carpeta con el agente vivo).
    static func terminateProcess(graceSeconds: Int = stopGraceSeconds) -> String {
        [
            "kill -TERM -- \"-$p\" 2>/dev/null || kill -TERM \"$p\" 2>/dev/null",
            "i=0; while kill -0 \"$p\" 2>/dev/null && [ $i -lt \(graceSeconds) ]; do sleep 1; i=$((i+1)); done",
            "if kill -0 \"$p\" 2>/dev/null; then kill -KILL -- \"-$p\" 2>/dev/null || kill -KILL \"$p\" 2>/dev/null; sleep 1; fi",
            "if kill -0 \"$p\" 2>/dev/null; then echo \(stuckMarker) >&2; exit 5; fi",
        ].joined(separator: "; ")
    }

    /// Anota en `meta.json` que el agente se hibernó (si no lo estaba ya). `meta.json` es
    /// JSON con sangría cuya última línea es `}`: se añade la clave antes de cerrarlo.
    static func markHibernated(_ dir: String) -> String {
        "if [ -f \(dir)/meta.json ] && ! grep -q '\"hibernatedAt\"' \(dir)/meta.json; then "
            + "t=$(date -u +%Y-%m-%dT%H:%M:%SZ); "
            + "( umask 077 && sed '$ s/}[[:space:]]*$/,\"hibernatedAt\":\"'\"$t\"'\"}/' \(dir)/meta.json > \(dir)/meta.json.tmp ) "
            + "&& mv \(dir)/meta.json.tmp \(dir)/meta.json; fi"
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
    /// con el cerrojo cogido): conserva el final desde una línea completa y suma a
    /// `log.base` lo quitado, así los desplazamientos ABSOLUTOS siguen valiendo.
    static func rotateOutputLog(_ dir: String) -> String {
        let out = "\(dir)/out.ndjson"
        return "os=$(wc -c < \(out) 2>/dev/null | tr -d ' '); "
            + "if [ \"${os:-0}\" -gt \(outLogMaxBytes) ]; then "
            + "\(readBase(dir)); "
            + "tail -c \(outLogKeepBytes) \(out) > \(dir)/out.tmp && "
            + "l=$(head -n 1 \(dir)/out.tmp | wc -c | tr -d ' ') && "
            + "tail -c +$((l + 1)) \(dir)/out.tmp > \(dir)/out.new && "
            + "k=$(wc -c < \(dir)/out.new | tr -d ' ') && "
            + "echo $((b + os - k)) > \(dir)/log.base && mv \(dir)/out.new \(out); "
            + "rm -f \(dir)/out.tmp \(dir)/out.new; fi"
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

    /// Vigilante de inactividad. Corre aparte (`sh -c` con `$1` = pid del agente) y
    /// termina solo en cuanto ese proceso deja de ser el agente (parado, reanudado con
    /// otro pid o muerto). Si el log no cambia en `idleSeconds` y el agente está quieto,
    /// lo hiberna: lo anota en `meta.json` y lo para como `stop`.
    static func watchdog(id: String, idleSeconds: Int, checkSeconds: Int) -> String {
        let dir = PersistentAgentScript.directory(id)
        return [
            "p=$1",
            "while sleep \(checkSeconds); do",
            "[ \"$(cat \(dir)/pid 2>/dev/null)\" = \"$p\" ] || exit 0",
            "kill -0 \"$p\" 2>/dev/null || exit 0",
            trimErrorLog(dir),
            "now=$(date +%s); \(modificationTime("\(dir)/out.ndjson")); [ -n \"$m\" ] || m=$now",
            "[ $((now - m)) -ge \(idleSeconds) ] || continue",
            lastSignificantLine(dir),
            "\(isQuiescentTest) || continue",
            markHibernated(dir),
            terminateProcess(),
            // Solo si sigue siendo su pid: un «Reanudar» simultáneo ya pudo escribir otro.
            "[ \"$(cat \(dir)/pid 2>/dev/null)\" = \"$p\" ] && rm -f \(dir)/pid; exit 0",
            "done",
        ].joined(separator: "\n")
    }
}

/// Hibernación de agentes persistentes: cuánto tiempo sin actividad se aguanta antes de
/// parar un agente quieto (se reanuda solo al escribirle).
struct PersistentAgentHibernation: Equatable, Sendable {
    /// Segundos sin actividad antes de hibernar; 0 = nunca.
    let idleSeconds: Int
    /// Cada cuánto mira el vigilante (segundos).
    let checkSeconds: Int

    static let defaultIdleHours = 4
    static let defaultCheckSeconds = 300
    static let choices = [0, 1, 2, 4, 8, 24]
    static let standard = PersistentAgentHibernation(idleHours: defaultIdleHours)

    init(idleHours: Int) {
        self.init(idleSeconds: max(0, idleHours) * 3600, checkSeconds: Self.defaultCheckSeconds)
    }

    init(idleSeconds: Int, checkSeconds: Int) {
        self.idleSeconds = max(0, idleSeconds)
        self.checkSeconds = max(1, checkSeconds)
    }

    var isEnabled: Bool { idleSeconds > 0 }
    var idleHours: Int { idleSeconds / 3600 }

    static func title(forHours hours: Int) -> String {
        switch hours {
        case 0: return "Nunca"
        case 1: return "1 hora"
        default: return "\(hours) horas"
        }
    }
}

/// Preferencia del dispositivo: horas de inactividad antes de hibernar.
enum AgentHibernationPreferences {
    static let key = "agent.hibernation.idleHours"

    static func idleHours(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: key) != nil else { return PersistentAgentHibernation.defaultIdleHours }
        let stored = defaults.integer(forKey: key)
        return PersistentAgentHibernation.choices.contains(stored) ? stored : PersistentAgentHibernation.defaultIdleHours
    }

    static func setIdleHours(_ hours: Int, defaults: UserDefaults = .standard) {
        defaults.set(hours, forKey: key)
    }

    static func current(defaults: UserDefaults = .standard) -> PersistentAgentHibernation {
        PersistentAgentHibernation(idleHours: idleHours(defaults: defaults))
    }
}
