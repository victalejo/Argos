//
//  PersistentAgentScript.swift
//  Argos
//
//  Agente PERSISTENTE en el servidor: `claude` corre desacoplado de la conexión SSH,
//  así que sigue trabajando aunque el iPhone se bloquee, cambie de red o se cierre la
//  app (iOS mata el SSH en segundo plano).
//
//  Cada agente vive en `~/.config/argos/agents/<id>/` (id = session id de Claude):
//   - `in`          FIFO por la que se le escribe (prompts y respuestas a permisos).
//                   claude la abre en lectura-escritura (`0<>`), así nunca ve EOF
//                   cuando no hay ningún cliente conectado.
//   - `out.ndjson`  todo lo que emite claude (stream-json) + una marca por cada permiso
//                   respondido. Reconectar = seguir el log (`tail -c +N -F`) desde lo
//                   último leído y reconstruir la conversación.
//   - `pid`, `meta.json` (carpeta, título, fecha), `err.log`.
//   - (aditivos) `log.base` y `"hibernatedAt"` en `meta.json`: ver `PersistentAgentShell`.
//
//  Aquí solo se construyen los comandos de shell (lógica pura, testeable).
//

import Foundation

/// Un agente persistente tal como lo lista el servidor.
struct PersistentAgentInfo: Identifiable, Equatable, Sendable {
    let id: String
    let isAlive: Bool
    /// Bytes ABSOLUTOS del log (incluidos los rotados).
    let logBytes: Int
    let meta: PersistentAgentMeta
}

struct PersistentAgentMeta: Codable, Equatable, Sendable {
    var workingDirectory: String
    var title: String
    var createdAt: Date
    /// Modo con el que se creó. Reanudar lo conserva para que nunca suban los permisos sin
    /// que nadie lo pida. Es texto para que un modo desconocido no invalide el `meta.json`.
    /// El archivo vive en el servidor y puede editarlo el propio agente: no es de fiar para
    /// dar permisos sin preguntar (ver `resumeRequiresConfirmation`).
    var permissionMode: String? = nil
    /// Cuándo lo hibernó el vigilante por inactividad (`nil` si no). Lo escribe el
    /// servidor; al reanudar se quita. Es aditivo: las versiones antiguas lo ignoran.
    var hibernatedAt: Date? = nil

    /// Hibernado (parado por inactividad): escribirle lo reanuda solo.
    var isHibernated: Bool { hibernatedAt != nil }

    /// Los agentes sin modo guardado se crearon preguntando cada permiso.
    var resolvedPermissionMode: ClaudeAgentCommand.PermissionMode {
        permissionMode.flatMap(ClaudeAgentCommand.PermissionMode.init(rawValue:)) ?? .default
    }

    /// Reanudar sin preguntar permitiría a un agente limitado subirse los permisos
    /// editando su `meta.json`, así que el usuario debe confirmar los modos que actúan
    /// sin pedir permiso. `default` y `plan` siguen preguntando antes de cada acción.
    var resumeRequiresConfirmation: Bool {
        switch resolvedPermissionMode {
        case .bypassPermissions, .acceptEdits: return true
        case .default, .plan: return false
        }
    }
}

enum PersistentAgentScript {

    static let rootRelativePath = ".config/argos/agents"

    /// Marca que Argos anexa al log al responder un permiso (el `control_response` va
    /// solo a la FIFO). Releer el log sabe así que ese permiso ya se respondió.
    static let answeredEventType = "argos_permission_answered"

    /// Primera línea que imprime `attach` (no está en el log): base de rotación y byte
    /// local desde el que sigue. Las versiones antiguas no la piden ni la ven.
    static let logBaseEventType = "argos_log_base"

    /// Respuestas del lanzador y del envío por stdin (primera línea de stdout).
    static let aliveReply = "ARGOS_AGENT_ALIVE"
    static let busyReply = "ARGOS_AGENT_BUSY"
    static let deadReply = "ARGOS_AGENT_DEAD"
    static let failedReply = "ARGOS_AGENT_FAILED"
    static let sentReply = "ARGOS_SENT"
    static let shortReply = "ARGOS_SEND_SHORT"
    static let timeoutReply = "ARGOS_SEND_TIMEOUT"

    /// Un argumento no puede pasar de 128 KiB (`MAX_ARG_STRLEN` de Linux) y el script
    /// entero va en UN argumento de `sh -c`.
    static let maxInlineCommandBytes = 96 * 1024
    /// Línea máxima (bytes) que va dentro del comando. Muy por debajo del búfer de una
    /// FIFO (64 KiB en Linux): escribirla nunca se bloquea aunque nadie la lea. Las mayores
    /// van por stdin con un escritor vigilado (`sendViaStdin`).
    static let maxInlineLineBytes = 16 * 1024
    /// Segundos que el escritor vigilado espera a que claude lea la línea.
    static let sendTimeoutSeconds = 30

    /// Bytes del final de `err.log` que se muestran cuando el agente no arranca.
    static let errorTailBytes = 1_500

    /// `"$HOME/.config/argos/agents/<id>"` (entre comillas dobles: `$HOME` se expande).
    /// Los ids son UUID: cualquier otra cosa es un error de programación (nunca debe
    /// llegar al shell, y menos a un `rm -rf`).
    static func directory(_ id: String) -> String {
        precondition(isValidID(id), "id de agente no válido")
        return "\"$HOME/\(rootRelativePath)/\(id)\""
    }

    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// Comprueba que el `pid` guardado es DE VERDAD este agente (y lo deja en `$p`): tras
    /// reiniciarse el servidor, ese número puede pertenecer a otro proceso (tmux, un
    /// editor…) y no hay que darlo por vivo ni matarlo. La línea de comandos de claude
    /// lleva el id (`--session-id`/`--resume`), que sirve de huella.
    static func aliveCheck(_ id: String) -> String {
        let dir = directory(id)
        return "{ p=$(cat \(dir)/pid 2>/dev/null); [ -n \"$p\" ] && ps -o args= -p \"$p\" 2>/dev/null | grep -q -- '\(id)'; }"
    }

    // MARK: - Lanzar

    /// Arranca el agente (o lo REANUDA si su proceso había terminado) en segundo plano e
    /// imprime su PID; si ya está vivo, no lanza otro e imprime `ARGOS_AGENT_ALIVE`. Si
    /// muere nada más arrancar, imprime `ARGOS_AGENT_FAILED <final de err.log en base64>`.
    ///
    /// La PRIMERA línea de stdin es el token OAuth (o vacía): así no viaja en ninguna
    /// línea de comandos (`ps`, auditoría). `claudeInvocation` es `env … claude <flags>`
    /// (ver `ClaudeAgentCommand.persistent`). Con el agente parado y el cerrojo cogido se
    /// recortan los logs; con `hibernation` activa, un vigilante lo hiberna si se queda
    /// quieto ese tiempo.
    static func launch(
        id: String,
        meta: PersistentAgentMeta,
        claudeInvocation: String,
        hibernation: PersistentAgentHibernation = .standard
    ) throws -> String {
        let dir = directory(id)
        let metaJSON = String(decoding: try JSONEncoder.projects.encode(meta), as: UTF8.self)
        let metaB64 = Data(metaJSON.utf8).base64EncodedString()
        let cd = ClaudeAgentCommand.cdTarget(for: meta.workingDirectory)
        // El token se exporta con un builtin (nunca como argumento) y se borra la copia.
        let inner = [
            "[ -n \"$ARGOS_OAUTH\" ] && export CLAUDE_CODE_OAUTH_TOKEN=\"$ARGOS_OAUTH\"",
            "unset ARGOS_OAUTH",
            "cd \(cd) && exec \(claudeInvocation) 0<>\(dir)/in >>\(dir)/out.ndjson 2>>\(dir)/err.log",
        ].joined(separator: "; ")
        // Preparación con umask 077 en un SUBSHELL: la carpeta del agente queda privada,
        // pero claude conserva el umask normal para los archivos que cree en el repo.
        let prepare = "( umask 077 && mkdir -p \(dir) && cd \(dir) && { [ -p in ] || mkfifo in; } "
            + "&& printf '%s' '\(metaB64)' | base64 -d > meta.json && touch out.ndjson err.log )"
        let spawn = "{ command -v setsid >/dev/null 2>&1 && S=setsid || S=; } && "
            + "{ nohup $S sh -c \(ShellQuoting.singleQuoted(inner)) >/dev/null 2>&1 < /dev/null & echo $! > \(dir)/pid; }"
        // Si claude muere al arrancar (opción desconocida, binario roto…), se dice por qué.
        let verify = "P=$(cat \(dir)/pid); sleep 1; if ! kill -0 \"$P\" 2>/dev/null; then "
            + "printf '%s %s\\n' \(failedReply) \"$(tail -c \(errorTailBytes) \(dir)/err.log 2>/dev/null | base64 | tr -d '\\n')\"; "
            + "rm -f \(dir)/pid; exit 6; fi"
        // `mkdir` como cerrojo atómico: dos «Reanudar» a la vez (Mac e iPhone) no lanzan
        // dos claude sobre la misma FIFO. Se espera un poco: el vigilante lo coge mientras
        // hiberna (unos segundos).
        let lock = PersistentAgentShell.lockPath(id)
        // Vivo: se reescribe `meta.json` igualmente (quita una marca `hibernatedAt` de una
        // hibernación que no llegó a pararlo).
        let alive = "if \(aliveCheck(id)); then "
            + "( umask 077 && printf '%s' '\(metaB64)' | base64 -d > \(dir)/meta.json.tmp ) && mv \(dir)/meta.json.tmp \(dir)/meta.json; "
            + "echo \(aliveReply); exit 0; fi"
        var lines = [
            "IFS= read -r ARGOS_OAUTH; export ARGOS_OAUTH",
            "mkdir -p \"$HOME/\(rootRelativePath)\" && chmod 700 \"$HOME/\(rootRelativePath)\"",
            // Un cerrojo de más de un minuto es de un lanzamiento que se interrumpió.
            PersistentAgentShell.clearStaleLock(id),
            PersistentAgentShell.acquireLock(
                id, waitSeconds: PersistentAgentShell.lockWaitSeconds, onBusy: "echo \(busyReply); exit 4"
            ),
            "trap 'rmdir \(lock) 2>/dev/null' EXIT",
            alive,
            "\(prepare) || exit 1",
            // Agente parado y cerrojo cogido: momento seguro para recortar los logs.
            PersistentAgentShell.rotateOutputLog(dir),
            PersistentAgentShell.trimErrorLog(dir),
            "\(spawn) || exit 1",
            verify,
        ]
        if hibernation.isEnabled {
            let watch = PersistentAgentShell.watchdog(
                id: id, idleSeconds: hibernation.idleSeconds, checkSeconds: hibernation.checkSeconds
            )
            lines.append("nohup $S sh -c \(ShellQuoting.singleQuoted(watch)) argos-watch \"$P\" >/dev/null 2>&1 < /dev/null &")
        }
        lines.append("echo \"$P\"")
        return lines.joined(separator: "\n")
    }

    // MARK: - Enviar

    /// Escribe una línea NDJSON en la FIFO del agente. Viaja en base64: el contenido
    /// nunca se interpreta en el shell. La FIFO se abre en lectura-escritura, que no se
    /// bloquea aunque claude acabe de morir. Si `answeredRequestID` no es nil (respuesta a
    /// un permiso), DESPUÉS de entregarla se anota en el log que ya se respondió.
    /// Para líneas grandes (ver `needsStdin`) se usa `sendViaStdin`.
    ///
    /// Con el cerrojo del vigilante: o la línea llega antes de que se hiberne (y se toca el
    /// log, así que ya no está quieto y no se hiberna) o se ve hibernado y se responde
    /// «muerto» (el cliente lo reanuda y reenvía). Nunca se da por enviada una línea que
    /// el vigilante va a tirar al parar a claude.
    static func send(id: String, line: String, answeredRequestID: String? = nil) -> String {
        let dir = directory(id)
        let b64 = Data((line + "\n").utf8).base64EncodedString()
        let dead = "{ echo '\(deadReply)' >&2; exit 3; }"
        var command = "\(deliverable(id)) || \(dead); "
            + PersistentAgentShell.lockForDelivery(id, onBusy: "echo '\(busyReply)' >&2; exit 4") + "; "
            + "\(deliverable(id)) || \(dead); "
            + "exec 3<>\(dir)/in && printf '%s' '\(b64)' | base64 -d >&3 && \(PersistentAgentShell.touchLog(dir))"
        if let answeredRequestID {
            command += " && " + appendAnsweredMarker(dir: dir, requestID: answeredRequestID)
        }
        return command
    }

    /// Vivo Y no hibernándose: con `hibernatedAt` el vigilante ya lo está parando y lo
    /// escrito se perdería (el cliente lo reanuda y reenvía).
    static func deliverable(_ id: String) -> String {
        "{ \(aliveCheck(id)) && ! \(PersistentAgentShell.isMarkedHibernated(directory(id))); }"
    }

    /// ¿La línea es demasiado grande para ir dentro del comando?
    static func needsStdin(line: String) -> Bool {
        line.utf8.count + 1 > maxInlineLineBytes
    }

    /// Variante para líneas grandes (un `Write` de 70 KB que aprobar): la línea llega por
    /// la ENTRADA ESTÁNDAR del canal (una sola línea: el JSON no lleva saltos), se guarda
    /// en un archivo privado, se comprueba que llegó entera (`byteCount` = bytes de la
    /// línea con su `\n`) y solo entonces se escribe en la FIFO. Responde por stdout con
    /// `ARGOS_SENT`, `ARGOS_AGENT_DEAD`, `ARGOS_SEND_SHORT` o `ARGOS_SEND_TIMEOUT`.
    ///
    /// La escritura va en SEGUNDO PLANO y vigilada: una línea mayor que el búfer de la FIFO
    /// se bloquea si claude no lee (muerto o colgado), y como este script tiene la FIFO
    /// abierta también para leer, nunca llegaría un SIGPIPE. Si el agente muere o pasan
    /// `sendTimeoutSeconds`, se mata al escritor y el script termina: al cerrarse la FIFO
    /// sin nadie más, lo que quedara en ella se descarta (no le llega a otro claude).
    /// Como `send`, la comprobación y la escritura van con el cerrojo del vigilante
    /// (`ARGOS_AGENT_BUSY` si no se consigue a tiempo).
    static func sendViaStdin(
        id: String,
        byteCount: Int,
        answeredRequestID: String? = nil,
        timeoutSeconds: Int = sendTimeoutSeconds
    ) -> String {
        let dir = directory(id)
        let file = "\(dir)/.send.$$"
        let ticks = max(1, timeoutSeconds) * 5
        var lines = [
            "\(deliverable(id)) || { echo \(deadReply); exit 3; }",
            "( umask 077 && head -n 1 > \(file) )",
            "n=$(wc -c < \(file) | tr -d ' ')",
            "if [ \"$n\" != \"\(byteCount)\" ]; then rm -f \(file); echo \(shortReply); exit 7; fi",
            PersistentAgentShell.lockForDelivery(id, onBusy: "rm -f \(file); echo \(busyReply); exit 4"),
            "\(deliverable(id)) || { rm -f \(file); echo \(deadReply); exit 3; }",
            "exec 3<>\(dir)/in || { rm -f \(file); exit 1; }",
            "cat \(file) >&3 & w=$!",
            "i=0; while kill -0 \"$w\" 2>/dev/null; do",
            "if ! \(aliveCheck(id)); then kill \"$w\" 2>/dev/null; rm -f \(file); echo \(deadReply); exit 3; fi",
            "if [ $i -ge \(ticks) ]; then kill \"$w\" 2>/dev/null; rm -f \(file); echo \(timeoutReply); exit 8; fi",
            "sleep 0.2; i=$((i+1)); done",
            "wait \"$w\"; r=$?; rm -f \(file); [ $r -eq 0 ] || exit 1",
            PersistentAgentShell.touchLog(dir),
        ]
        if let answeredRequestID {
            lines.append(appendAnsweredMarker(dir: dir, requestID: answeredRequestID) + " || exit 1")
        }
        lines.append("echo \(sentReply)")
        return lines.joined(separator: "\n")
    }

    private static func appendAnsweredMarker(dir: String, requestID: String) -> String {
        let marker: [String: String] = ["type": answeredEventType, "request_id": requestID]
        let json = (try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])) ?? Data()
        let markerB64 = (json + Data("\n".utf8)).base64EncodedString()
        return "printf '%s' '\(markerB64)' | base64 -d >> \(dir)/out.ndjson"
    }

    // MARK: - Enganche

    /// Sigue el log desde el byte ABSOLUTO `fromByte` (1 = desde el principio). Antes de
    /// los datos imprime UNA línea `{"type":"argos_log_base","base":B,"from":S}`: `B` son
    /// los bytes rotados y `S` el byte local desde el que sigue (si lo pedido ya se rotó,
    /// `S` = 1 y el cliente debe reconstruir desde ahí). El `tail` muere cuando se cierra
    /// el canal SSH (EOF en stdin): si no, cada reconexión dejaría un `tail` huérfano.
    /// Mientras se rota (`.rotating`) espera hasta 10 s. Si lo pedido queda más allá del
    /// final del archivo (desplazamientos que ya no cuadran), responde `S` = 1 para que el
    /// cliente reconstruya en vez de quedarse esperando bytes que no llegarán. Si el log
    /// empieza por la marca de rotación (ver `PersistentAgentShell.rotateOutputLog`), nunca
    /// se envía: se sigue desde justo después (si no, el cliente se reengancharía sin fin).
    static func attach(id: String, fromByte: Int = 1) -> String {
        let dir = directory(id)
        let mark = PersistentAgentShell.rotatedLineBytes
        return "w=0; while [ -e \(dir)/.rotating ] && [ $w -lt 50 ]; do sleep 0.2; w=$((w+1)); done; "
            + "\(PersistentAgentShell.readBase(dir)); s=$((\(max(1, fromByte)) - b)); [ \"$s\" -ge 1 ] || s=1; "
            + "sz=$(wc -c < \(dir)/out.ndjson 2>/dev/null | tr -d ' '); [ \"$s\" -le $(( ${sz:-0} + 1 )) ] || s=1; "
            + "if [ \"$s\" -le \(mark) ] && [ \"$(head -c \(mark) \(dir)/out.ndjson 2>/dev/null)\" = '\(PersistentAgentShell.rotatedLine)' ]; then s=\(mark + 1); fi; "
            + "printf '{\"type\":\"\(logBaseEventType)\",\"base\":%s,\"from\":%s}\\n' \"$b\" \"$s\"; "
            + "tail -c +\"$s\" -F \(dir)/out.ndjson 2>/dev/null & T=$!; "
            + "trap 'kill $T 2>/dev/null' EXIT HUP TERM; cat > /dev/null; kill $T 2>/dev/null"
    }

    /// Cabecera de `attach`: (base, byte local de inicio), o `nil` si `line` no lo es.
    static func parseLogBase(_ line: String) -> (base: Int, from: Int)? {
        guard line.contains(logBaseEventType),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == logBaseEventType,
              let base = object["base"] as? Int, let from = object["from"] as? Int,
              base >= 0, from >= 1
        else { return nil }
        return (base, from)
    }

    // MARK: - Parar / hibernar

    /// Termina el agente (solo si es de verdad el agente): TERM al grupo, espera, KILL.
    /// Con `delete`, borra su carpeta, pero SOLO si el proceso murió (si no, sale con
    /// `ARGOS_AGENT_STUCK` y la carpeta sigue ahí, visible y reintentable).
    static func stop(id: String, delete: Bool, graceSeconds: Int = PersistentAgentShell.stopGraceSeconds) -> String {
        let dir = directory(id)
        let terminate = PersistentAgentShell.terminateProcess(id: id, graceSeconds: graceSeconds)
        let kill = "{ if \(aliveCheck(id)); then \(terminate); fi; rm -f \(dir)/pid; true; }"
        return delete ? "\(kill) && rm -rf \(dir)" : kill
    }

    /// Hiberna a demanda («Hibernar inactivos»), pero solo si EN EL SERVIDOR sigue quieto
    /// y sin actividad desde hace `minIdleSeconds` (el inventario de la vista puede estar
    /// viejo): con el cerrojo, comprueba como el vigilante, lo anota y lo para. Imprime
    /// `ARGOS_HIBERNATED <id>` si lo hizo.
    static func hibernate(id: String, minIdleSeconds: Int) -> String {
        [
            aliveCheck(id) + " || exit 0",
            PersistentAgentShell.acquireLock(id, waitSeconds: 5, onBusy: "exit 0"),
            "trap '\(PersistentAgentShell.releaseLock(id))' EXIT",
            "h=0",
            PersistentAgentShell.hibernateIfQuiet(id: id, minIdleSeconds: max(0, minIdleSeconds)),
            "[ \"$h\" = 1 ] && echo \(hibernatedReply) \(id)",
            "true",
        ].joined(separator: "\n")
    }

    static let hibernatedReply = "ARGOS_HIBERNATED"

    /// Final de `err.log` (para explicar por qué el agente no está en marcha).
    static func errorTail(id: String) -> String {
        "tail -c \(errorTailBytes) \(directory(id))/err.log 2>/dev/null; true"
    }

    // MARK: - Listado

    /// `$size` += `log.base` de la carpeta `$d` (dentro de los bucles de listado).
    static let absoluteSize = "b=$(cat \"$d/log.base\" 2>/dev/null); case \"$b\" in ''|*[!0-9]*) b=0;; esac; size=$(( ${size:-0} + b ))"

    /// Una línea por agente: `id|vivo(0/1)|bytes del log|meta.json en base64`. Los bytes
    /// son ABSOLUTOS (incluyen los rotados, `log.base`).
    static func list() -> String {
        """
        for d in "$HOME/\(rootRelativePath)"/*/; do \
        [ -f "$d/meta.json" ] || continue; \
        id=$(basename "$d"); p=$(cat "$d/pid" 2>/dev/null); alive=0; \
        [ -n "$p" ] && ps -o args= -p "$p" 2>/dev/null | grep -q -- "$id" && alive=1; \
        size=$(wc -c < "$d/out.ndjson" 2>/dev/null | tr -d ' '); \
        \(absoluteSize); \
        printf '%s|%s|%s|' "$id" "$alive" "$size"; \
        base64 < "$d/meta.json" | tr -d '\\n'; echo; \
        done
        """
    }

    static func parseList(_ output: String) -> [PersistentAgentInfo] {
        let decoder = JSONDecoder.projects
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  isValidID(String(fields[0])),
                  let data = Data(base64Encoded: String(fields[3])),
                  let meta = try? decoder.decode(PersistentAgentMeta.self, from: data)
            else { return nil }
            return PersistentAgentInfo(
                id: String(fields[0]),
                isAlive: fields[1] == "1",
                logBytes: Int(fields[2]) ?? 0,
                meta: meta
            )
        }
        .sorted { $0.meta.createdAt > $1.meta.createdAt }
    }
}
