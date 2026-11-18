//
//  ServerAgentInventory.swift
//  Argos
//
//  TODOS los agentes de Argos vivos en un servidor, de cualquier proyecto: los
//  persistentes (carpeta `~/.config/argos/agents/<id>`) y los del panel Agente del Mac
//  (`claude -p --input-format stream-json` SIN `--replay-user-messages`), con su memoria
//  residente e inactividad. Un solo comando; el análisis es puro y testeable.
//
//  Nunca aparece un `claude` interactivo (tmux) ni uno ajeno a Argos: se exige la forma
//  exacta de la invocación headless de Argos y un id de sesión UUID.
//

import Foundation

/// Un agente de Argos vivo (o parado, si es persistente) en el servidor.
struct ServerAgentProcess: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Agente persistente (iPhone/iPad/Android): se para por su carpeta.
        case persistent(PersistentAgentMeta)
        /// Conversación del panel Agente del Mac: se para por PID.
        case panel(pid: Int32)
    }

    /// Id de sesión de Claude (UUID en minúsculas).
    let sessionID: String
    let kind: Kind
    let isAlive: Bool
    /// Memoria residente (KB); 0 si está parado o no se sabe.
    let residentKB: Int
    /// Segundos desde la última escritura en su log (`nil` en los del panel: no tienen).
    let idleSeconds: Int?
    /// Hay un permiso sin responder (solo persistentes).
    let hasPendingPermission: Bool

    var id: String { sessionID }

    var title: String {
        switch kind {
        case .persistent(let meta): return meta.title
        case .panel: return "Conversación del Mac"
        }
    }
}

struct ServerAgentInventory: Equatable, Sendable {
    let agents: [ServerAgentProcess]
    /// `MemAvailable` del servidor (KB), si es Linux.
    let freeMemoryKB: Int?

    var liveAgents: [ServerAgentProcess] { agents.filter(\.isAlive) }
    var liveResidentKB: Int { liveAgents.reduce(0) { $0 + $1.residentKB } }

    /// Persistentes vivos, quietos (sin permiso pendiente) y sin actividad desde hace al
    /// menos `idleSeconds`: los que «Hibernar inactivos» puede parar sin perder nada.
    func hibernationCandidates(idleSeconds: Int) -> [ServerAgentProcess] {
        agents.filter { agent in
            guard agent.isAlive, !agent.hasPendingPermission, case .persistent = agent.kind,
                  let idle = agent.idleSeconds else { return false }
            return idle >= idleSeconds
        }
    }
}

extension ServerAgentInventory {

    /// Una línea por agente persistente:
    /// `P|id|vivo|rss KB|segundos inactivo|bytes|permiso pendiente(0/1)|meta en base64`;
    /// una por proceso headless de claude: `M|pid|rss KB|línea de comandos`; y
    /// `MEM|KB disponibles`. El patrón `stream-[j]son` evita que el propio comando (que
    /// contiene el texto) se encuentre a sí mismo.
    static func script() -> String {
        let root = "$HOME/\(PersistentAgentScript.rootRelativePath)"
        let persistent = """
        now=$(date +%s); \
        for d in "\(root)"/*/; do \
        [ -f "$d/meta.json" ] || continue; \
        id=$(basename "$d"); p=$(cat "$d/pid" 2>/dev/null); alive=0; rss=0; \
        if [ -n "$p" ] && ps -o args= -p "$p" 2>/dev/null | grep -q -- "$id"; then alive=1; rss=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' '); fi; \
        \(PersistentAgentShell.modificationTime("\"$d/out.ndjson\"")); idle=$(( now - ${m:-$now} )); \
        size=$(wc -c < "$d/out.ndjson" 2>/dev/null | tr -d ' '); \
        \(PersistentAgentScript.absoluteSize); \
        \(PersistentAgentShell.lastSignificantLine("\"$d\"")); pend=0; \
        case "$last" in *'"type":"control_request"'*) pend=1;; esac; \
        printf 'P|%s|%s|%s|%s|%s|%s|' "$id" "$alive" "${rss:-0}" "$idle" "$size" "$pend"; \
        base64 < "$d/meta.json" | tr -d '\\n'; echo; \
        done
        """
        let headless = "ps -eo pid=,rss=,args= 2>/dev/null | grep -- 'stream-[j]son' | sed 's/^ *//; s/^/M|/; s/  */|/; s/  */|/'"
        let memory = "printf 'MEM|%s\\n' \"$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)\""
        return [persistent, headless, memory, "true"].joined(separator: "\n")
    }

    static func parse(_ output: String) -> ServerAgentInventory {
        var agents: [ServerAgentProcess] = []
        var freeMemory: Int?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("MEM|") {
                freeMemory = Int(line.dropFirst(4).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("P|"), let agent = parsePersistent(line) {
                agents.append(agent)
            } else if line.hasPrefix("M|"), let agent = parsePanel(line) {
                agents.append(agent)
            }
        }
        let sorted = agents.sorted { lhs, rhs in
            if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
            return lhs.residentKB > rhs.residentKB
        }
        return ServerAgentInventory(agents: sorted, freeMemoryKB: freeMemory)
    }

    private static func parsePersistent(_ line: String) -> ServerAgentProcess? {
        let fields = line.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 8, PersistentAgentScript.isValidID(fields[1]),
              let data = Data(base64Encoded: fields[7]),
              let meta = try? JSONDecoder.projects.decode(PersistentAgentMeta.self, from: data)
        else { return nil }
        let alive = fields[2] == "1"
        return ServerAgentProcess(
            sessionID: fields[1].lowercased(),
            kind: .persistent(meta),
            isAlive: alive,
            residentKB: alive ? Int(fields[3]) ?? 0 : 0,
            idleSeconds: Int(fields[4]).map { max(0, $0) },
            hasPendingPermission: fields[6] == "1"
        )
    }

    private static func parsePanel(_ line: String) -> ServerAgentProcess? {
        let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, let pid = Int32(fields[1]), pid > 1,
              let sessionID = panelSessionID(arguments: fields[3])
        else { return nil }
        return ServerAgentProcess(
            sessionID: sessionID,
            kind: .panel(pid: pid),
            isAlive: true,
            residentKB: Int(fields[2]) ?? 0,
            idleSeconds: nil,
            hasPendingPermission: false
        )
    }

    /// Id de sesión si `arguments` es EXACTAMENTE una conversación del panel del Mac
    /// (`claude -p --input-format stream-json --output-format stream-json … --session-id
    /// <uuid>` o `--resume <uuid>`, sin `--replay-user-messages`, que es la marca de los
    /// persistentes). Cualquier otra cosa (claude interactivo en tmux, un `grep`, un
    /// shell que contenga el texto) devuelve `nil`.
    static func panelSessionID(arguments: String) -> String? {
        let tokens = arguments.split(separator: " ").map(String.init)
        guard let program = tokens.first(where: { !$0.hasPrefix("-") }),
              !["sh", "bash", "zsh", "dash", "grep", "sed"].contains((program as NSString).lastPathComponent),
              tokens.contains("-p"),
              hasPair(tokens, "--input-format", "stream-json"),
              hasPair(tokens, "--output-format", "stream-json"),
              hasPair(tokens, "--permission-prompt-tool", "stdio"),
              !tokens.contains("--replay-user-messages")
        else { return nil }
        for flag in ["--session-id", "--resume"] {
            if let index = tokens.firstIndex(of: flag), tokens.indices.contains(index + 1),
               UUID(uuidString: tokens[index + 1]) != nil {
                return tokens[index + 1].lowercased()
            }
        }
        return nil
    }

    private static func hasPair(_ tokens: [String], _ flag: String, _ value: String) -> Bool {
        guard let index = tokens.firstIndex(of: flag) else { return false }
        return tokens.indices.contains(index + 1) && tokens[index + 1] == value
    }

    // MARK: - Acciones

    /// Para varios persistentes (sin borrar nada: se pueden reanudar).
    static func stopPersistent(ids: [String]) -> String {
        ids.filter(PersistentAgentScript.isValidID)
            .map { PersistentAgentScript.stop(id: $0, delete: false) }
            .joined(separator: "\n") + "\ntrue"
    }

    /// Hiberna varios persistentes (se reanudan solos al escribirles).
    static func hibernate(ids: [String]) -> String {
        ids.filter(PersistentAgentScript.isValidID)
            .map { PersistentAgentScript.hibernate(id: $0) }
            .joined(separator: "\n") + "\ntrue"
    }

    /// Mata conversaciones del panel por PID, comprobando ANTES que cada PID sigue siendo
    /// esa conversación (`--input-format stream-json` y su id), con TERM y luego KILL.
    static func stopPanel(_ processes: [(pid: Int32, sessionID: String)]) -> String {
        let valid = processes.filter { $0.pid > 1 && UUID(uuidString: $0.sessionID) != nil }
        guard !valid.isEmpty else { return "true" }
        let checks = valid.map { process in
            "if ps -o args= -p \(process.pid) 2>/dev/null | grep -q -- 'input-format stream-json' "
                + "&& ps -o args= -p \(process.pid) 2>/dev/null | grep -qi -- '\(process.sessionID)'; then "
                + "kill -TERM \(process.pid) 2>/dev/null; K=\"$K \(process.pid)\"; fi"
        }
        return (["K="] + checks + [
            "[ -n \"$K\" ] && sleep 2",
            "for p in $K; do kill -KILL \"$p\" 2>/dev/null; done",
            "true",
        ]).joined(separator: "\n")
    }
}

extension SSHServicing {
    /// Lee el inventario de agentes del servidor (un viaje SSH).
    func serverAgentInventory() async throws -> ServerAgentInventory {
        ServerAgentInventory.parse(try await runAgentScript(ServerAgentInventory.script()))
    }
}
