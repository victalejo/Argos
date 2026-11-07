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
//                   respondido. Reconectar = releer el log desde el principio
//                   (`tail -c +1 -F`) y reconstruir la conversación.
//   - `pid`, `meta.json` (carpeta, título, fecha), `err.log`.
//
//  Aquí solo se construyen los comandos de shell (lógica pura, testeable).
//

import Foundation

/// Un agente persistente tal como lo lista el servidor.
struct PersistentAgentInfo: Identifiable, Equatable, Sendable {
    let id: String
    let isAlive: Bool
    let logBytes: Int
    let meta: PersistentAgentMeta
}

struct PersistentAgentMeta: Codable, Equatable, Sendable {
    var workingDirectory: String
    var title: String
    var createdAt: Date
}

enum PersistentAgentScript {

    static let rootRelativePath = ".config/argos/agents"

    /// Marca que Argos anexa al log al responder un permiso (el `control_response` va
    /// solo a la FIFO). Releer el log sabe así que ese permiso ya se respondió.
    static let answeredEventType = "argos_permission_answered"

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

    /// Comprueba que el `pid` guardado es DE VERDAD este agente: tras reiniciarse el
    /// servidor, ese número puede pertenecer a otro proceso (tmux, un editor…) y no hay
    /// que darlo por vivo ni matarlo. La línea de comandos de claude lleva el id
    /// (`--session-id`/`--resume`), que sirve de huella.
    private static func aliveCheck(_ id: String) -> String {
        let dir = directory(id)
        return "{ p=$(cat \(dir)/pid 2>/dev/null); [ -n \"$p\" ] && ps -o args= -p \"$p\" 2>/dev/null | grep -q -- '\(id)'; }"
    }

    // MARK: - Comandos

    /// Arranca el agente (o lo REANUDA si su proceso había terminado) en segundo plano e
    /// imprime su PID; si ya está vivo, no lanza otro e imprime `ARGOS_AGENT_ALIVE`.
    ///
    /// La PRIMERA línea de stdin es el token OAuth (o vacía): así no viaja en ninguna
    /// línea de comandos (`ps`, auditoría). `claudeInvocation` es `env … claude <flags>`
    /// (ver `ClaudeAgentCommand.persistent`).
    static func launch(id: String, meta: PersistentAgentMeta, claudeInvocation: String) throws -> String {
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
            + "{ nohup $S sh -c \(ShellQuoting.singleQuoted(inner)) >/dev/null 2>&1 < /dev/null & echo $! > \(dir)/pid; } && cat \(dir)/pid"
        // `mkdir` como cerrojo atómico: dos «Reanudar» a la vez (Mac e iPhone) no lanzan
        // dos claude sobre la misma FIFO.
        let lock = "\"$HOME/\(rootRelativePath)/.\(id).lock\""
        return [
            "IFS= read -r ARGOS_OAUTH; export ARGOS_OAUTH",
            "mkdir -p \"$HOME/\(rootRelativePath)\" && chmod 700 \"$HOME/\(rootRelativePath)\"",
            // Un cerrojo de más de un minuto es de un lanzamiento que se interrumpió.
            "find \"$HOME/\(rootRelativePath)\" -maxdepth 1 -name '.\(id).lock' -mmin +1 -exec rmdir {} \\; 2>/dev/null",
            "mkdir \(lock) 2>/dev/null || { echo ARGOS_AGENT_BUSY; exit 4; }",
            "trap 'rmdir \(lock) 2>/dev/null' EXIT",
            "if \(aliveCheck(id)); then echo ARGOS_AGENT_ALIVE; exit 0; fi",
            "\(prepare) && \(spawn)",
        ].joined(separator: "\n")
    }

    /// Escribe una línea NDJSON en la FIFO del agente. Viaja en base64: el contenido
    /// nunca se interpreta en el shell. La FIFO se abre en lectura-escritura, que no se
    /// bloquea aunque claude acabe de morir. Si `answeredRequestID` no es nil (respuesta a
    /// un permiso), DESPUÉS de entregarla se anota en el log que ya se respondió.
    static func send(id: String, line: String, answeredRequestID: String? = nil) -> String {
        let dir = directory(id)
        let b64 = Data((line + "\n").utf8).base64EncodedString()
        var command = "\(aliveCheck(id)) || { echo 'ARGOS_AGENT_DEAD' >&2; exit 3; }; "
            + "exec 3<>\(dir)/in && printf '%s' '\(b64)' | base64 -d >&3"
        if let answeredRequestID {
            let marker: [String: String] = ["type": answeredEventType, "request_id": answeredRequestID]
            let json = (try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])) ?? Data()
            let markerB64 = (json + Data("\n".utf8)).base64EncodedString()
            command += " && printf '%s' '\(markerB64)' | base64 -d >> \(dir)/out.ndjson"
        }
        return command
    }

    /// Sigue el log desde el byte `fromByte` (1 = desde el principio). El `tail` muere
    /// cuando se cierra el canal SSH (EOF en stdin): si no, cada reconexión del iPhone
    /// dejaría un `tail` huérfano en el servidor.
    static func attach(id: String, fromByte: Int = 1) -> String {
        "tail -c +\(max(1, fromByte)) -F \(directory(id))/out.ndjson 2>/dev/null & T=$!; "
            + "trap 'kill $T 2>/dev/null' EXIT HUP TERM; cat > /dev/null; kill $T 2>/dev/null"
    }

    /// Termina el proceso del agente (solo si es de verdad el agente). Con `delete`,
    /// borra también su carpeta y log.
    static func stop(id: String, delete: Bool) -> String {
        let dir = directory(id)
        let kill = "{ if \(aliveCheck(id)); then kill \"$p\"; fi; rm -f \(dir)/pid; true; }"
        return delete ? "\(kill); rm -rf \(dir)" : kill
    }

    /// Una línea por agente: `id|vivo(0/1)|bytes del log|meta.json en base64`.
    static func list() -> String {
        """
        for d in "$HOME/\(rootRelativePath)"/*/; do \
        [ -f "$d/meta.json" ] || continue; \
        id=$(basename "$d"); p=$(cat "$d/pid" 2>/dev/null); alive=0; \
        [ -n "$p" ] && ps -o args= -p "$p" 2>/dev/null | grep -q -- "$id" && alive=1; \
        size=$(wc -c < "$d/out.ndjson" 2>/dev/null | tr -d ' '); \
        printf '%s|%s|%s|' "$id" "$alive" "${size:-0}"; \
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
