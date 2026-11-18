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
        case .panel: return String(localized: "Conversación del Mac")
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

    /// Marca que imprime una acción por cada agente que no pudo parar o hibernar.
    static let failedMarker = "ARGOS_ACTION_FAILED"

    /// Para varios persistentes (sin borrar nada: se pueden reanudar). Cada parada va en
    /// su propio subshell: uno atascado no impide parar los demás, y queda anotado.
    static func stopPersistent(ids: [String]) -> String {
        ids.filter(PersistentAgentScript.isValidID)
            .map { "( \(PersistentAgentScript.stop(id: $0, delete: false)) ) || echo \(failedMarker) \($0)" }
            .joined(separator: "\n") + "\ntrue"
    }

    /// Hiberna varios persistentes si EN EL SERVIDOR siguen quietos desde hace al menos
    /// `minIdleSeconds` (se reanudan solos al escribirles).
    static func hibernate(ids: [String], minIdleSeconds: Int) -> String {
        ids.filter(PersistentAgentScript.isValidID)
            .map { "( \(PersistentAgentScript.hibernate(id: $0, minIdleSeconds: minIdleSeconds)) ) || echo \(failedMarker) \($0)" }
            .joined(separator: "\n") + "\ntrue"
    }

    /// Ids que una acción no pudo completar (ver `failedMarker`).
    static func failures(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0] == failedMarker else { return nil }
            return String(parts[1])
        }
    }

    /// Función de shell `pm PID ID`: verdadero si EN ESTE INSTANTE el PID es una
    /// conversación del panel con ese id (no un shell, `grep` u otro programa que lleve
    /// el texto, ni un persistente).
    static let panelMatchFunction = "pm() { c=$(ps -o comm= -p \"$1\" 2>/dev/null); "
        + "case \"${c##*/}\" in ''|sh|bash|dash|zsh|ksh|fish|grep|sed|awk|ps|ssh|sshd|tail|cat) return 1;; esac; "
        + "a=$(ps -o args= -p \"$1\" 2>/dev/null); "
        + "case \"$a\" in *--replay-user-messages*) return 1;; *'--input-format stream-json'*) ;; *) return 1;; esac; "
        + "printf '%s\\n' \"$a\" | grep -qi -- \"$2\"; }"

    /// TERM a las entradas `pid:id` de `$K` que sigan siendo suyas, espera hasta 5 s y
    /// KILL a las que sigan vivas (comprobando otra vez cada una).
    private static let terminatePanelEntries = [
        "for e in $K; do pm \"${e%%:*}\" \"${e#*:}\" && kill -s TERM \"${e%%:*}\" 2>/dev/null; done",
        "i=0; while [ -n \"$K\" ] && [ $i -lt 10 ]; do v=0; for e in $K; do pm \"${e%%:*}\" \"${e#*:}\" && v=1; done; "
            + "[ $v = 0 ] && break; sleep 0.5; i=$((i+1)); done",
        "for e in $K; do pm \"${e%%:*}\" \"${e#*:}\" && kill -s KILL \"${e%%:*}\" 2>/dev/null; done",
        "true",
    ]

    /// Mata conversaciones del panel por PID, comprobando en cada señal que el PID sigue
    /// siendo esa conversación (su id en la línea de comandos).
    static func stopPanel(_ processes: [(pid: Int32, sessionID: String)]) -> String {
        let valid = processes.filter { $0.pid > 1 && UUID(uuidString: $0.sessionID) != nil }
        guard !valid.isEmpty else { return "true" }
        let entries = valid.map { "\($0.pid):\($0.sessionID.lowercased())" }.joined(separator: " ")
        return ([panelMatchFunction, "K=", "for e in \(entries); do pm \"${e%%:*}\" \"${e#*:}\" && K=\"$K $e\"; done"]
            + terminatePanelEntries).joined(separator: "\n")
    }

    /// Mata TODAS las conversaciones del panel con esos ids de sesión, encontrándolas por
    /// su línea de comandos (sin depender de un PID guardado, que pudo reutilizarse).
    static func stopPanelSessions(_ sessionIDs: [String]) -> String {
        let ids = sessionIDs.map { $0.lowercased() }.filter { UUID(uuidString: $0) != nil }
        guard !ids.isEmpty else { return "true" }
        let find = ids.map { id in
            "for x in $(ps -eo pid=,args= 2>/dev/null | grep -i -- '\(id)' | awk '{print $1}'); do "
                + "pm \"$x\" '\(id)' && K=\"$K $x:\(id)\"; done"
        }
        return ([panelMatchFunction, "K="] + find + terminatePanelEntries).joined(separator: "\n")
    }
}

extension SSHServicing {
    /// Lee el inventario de agentes del servidor (un viaje SSH).
    func serverAgentInventory() async throws -> ServerAgentInventory {
        ServerAgentInventory.parse(try await runAgentScript(ServerAgentInventory.script()))
    }
}
