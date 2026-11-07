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
//   - `out.ndjson`  todo lo que emite claude (stream-json) + las respuestas a permisos
//                   que enviamos. Reconectar = releer el log desde el principio
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

    /// `"$HOME/.config/argos/agents/<id>"` (entre comillas dobles: `$HOME` se expande).
    static func directory(_ id: String) -> String {
        "\"$HOME/\(rootRelativePath)/\(id)\""
    }

    /// Los ids son UUID de sesión de Claude: se valida para que nunca entren en el
    /// shell caracteres que no lo sean (rutas, comillas…).
    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    // MARK: - Comandos

    /// Arranca el agente (o lo REANUDA si su proceso había terminado) en segundo plano.
    /// `claudeInvocation` es `env … claude <flags>` (ver `ClaudeAgentCommand.persistent`).
    /// Imprime el PID.
    static func launch(id: String, meta: PersistentAgentMeta, claudeInvocation: String) throws -> String {
        let dir = directory(id)
        let metaJSON = String(decoding: try JSONEncoder.projects.encode(meta), as: UTF8.self)
        let metaB64 = Data(metaJSON.utf8).base64EncodedString()
        let cd = ClaudeAgentCommand.cdTarget(for: meta.workingDirectory)
        // El proceso hereda la FIFO como stdin en lectura-escritura y anexa al log.
        let inner = "cd \(cd) && exec \(claudeInvocation) 0<>\(dir)/in >>\(dir)/out.ndjson 2>>\(dir)/err.log"
        let prepare = [
            "umask 077",
            "mkdir -p \(dir)",
            "cd \(dir)",
            "{ [ -p in ] || mkfifo in; }",
            "printf '%s' '\(metaB64)' | base64 -d > meta.json",
            "touch out.ndjson",
            // `setsid` (Linux) lo saca de la sesión SSH; `nohup` cubre los sistemas sin él.
            "{ command -v setsid >/dev/null 2>&1 && S=setsid || S=; }",
        ].joined(separator: " && ")
        let spawn = "{ nohup $S sh -c \(ShellQuoting.singleQuoted(inner)) >/dev/null 2>&1 < /dev/null & echo $! > pid; }"
        return "\(prepare) && \(spawn) && cat pid"
    }

    /// Escribe una línea NDJSON en la FIFO del agente. Si `log` es `true` (respuestas a
    /// permisos), la anexa también al log para que una reconexión sepa que ya se
    /// respondió. Viaja en base64: el contenido nunca se interpreta en el shell.
    static func send(id: String, line: String, log: Bool) -> String {
        let dir = directory(id)
        let b64 = Data((line + "\n").utf8).base64EncodedString()
        let decode = "printf '%s' '\(b64)' | base64 -d"
        let alive = "kill -0 \"$(cat \(dir)/pid)\" 2>/dev/null"
        let target = log ? "tee -a \(dir)/out.ndjson > \(dir)/in" : "cat > \(dir)/in"
        // Sin proceso vivo, escribir en la FIFO se bloquearía para siempre.
        return "\(alive) || { echo 'ARGOS_AGENT_DEAD' >&2; exit 3; }; \(decode) | \(target)"
    }

    /// Sigue el log desde el byte `fromByte` (1 = desde el principio) sin terminar.
    static func attach(id: String, fromByte: Int = 1) -> String {
        "exec tail -c +\(max(1, fromByte)) -F \(directory(id))/out.ndjson 2>/dev/null"
    }

    /// Termina el proceso del agente. Con `delete`, borra también su carpeta y log.
    static func stop(id: String, delete: Bool) -> String {
        let dir = directory(id)
        let kill = "{ [ -f \(dir)/pid ] && kill \"$(cat \(dir)/pid)\" 2>/dev/null; true; }"
        return delete ? "\(kill); rm -rf \(dir)" : kill
    }

    /// Una línea por agente: `id|vivo(0/1)|bytes del log|meta.json en base64`.
    static func list() -> String {
        """
        for d in "$HOME/\(rootRelativePath)"/*/; do \
        [ -f "$d/meta.json" ] || continue; \
        id=$(basename "$d"); pid=$(cat "$d/pid" 2>/dev/null); alive=0; \
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1; \
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
