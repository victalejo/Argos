//
//  AgentAttention.swift
//  Argos
//
//  ¿Necesita un agente persistente tu atención? Se decide leyendo el FINAL de su log
//  (lógica pura): pide permiso si hay un `control_request` sin responder, o terminó si
//  lo último relevante es un `result`. Lo usan los avisos en segundo plano del iPhone.
//
//  El final llega como las últimas líneas RECORTADAS (ver `snapshots`): un permiso de un
//  `Write` enorme no cabe entero, así que lo que no es JSON válido se lee de forma
//  tolerante (`AgentLogLineSummary`). Si algo no se pudo evaluar, no se da por visto.
//

import Foundation

enum AgentAttention: Equatable, Sendable {
    case none
    case needsPermission(tool: String)
    /// `seeded`: es el `result` que cierra un log sembrado (`AgentTranscriptSeed`), no un
    /// turno que terminara ahora: el agente está quieto, pero no se avisa de «terminó».
    case finished(summary: String?, isError: Bool, seeded: Bool = false)
    /// El final del log no se pudo interpretar (p. ej. un permiso sin `request_id`
    /// legible): no se avisa, pero tampoco se marca como visto.
    case undetermined

    /// Estado del agente según las últimas líneas de su log.
    static func evaluate(logTail: String) -> AgentAttention {
        var pending: AgentLogLineSummary?
        var outcome: AgentAttention = .none
        var recognized = false
        var unreadablePermission = false
        for raw in logTail.split(whereSeparator: \.isNewline) {
            guard let line = AgentLogLineSummary(line: String(raw)) else { continue }
            recognized = true
            switch line.kind {
            case .permissionRequest:
                if line.requestID == nil || line.toolName == nil {
                    unreadablePermission = true
                    pending = nil
                } else {
                    unreadablePermission = false
                    pending = line
                }
                outcome = .none
            case .permissionAnswered, .permissionCancel:
                if pending?.requestID == line.requestID { pending = nil }
                if line.requestID != nil { unreadablePermission = false }
            case .result:
                pending = nil
                unreadablePermission = false
                outcome = .finished(summary: line.resultText, isError: line.isError, seeded: line.isSeed)
            case .userPrompt:
                outcome = .none // un prompt nuevo: vuelve a trabajar
            case .other:
                break
            }
        }
        if let pending, let tool = pending.toolName { return .needsPermission(tool: pending.displayName ?? tool) }
        if unreadablePermission { return .undetermined }
        if !recognized && !logTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .undetermined }
        return outcome
    }

    /// Texto breve para una notificación (o `nil` si no hay nada que avisar).
    func notification(agentTitle: String) -> (title: String, body: String)? {
        switch self {
        case .none, .undetermined:
            return nil
        case .needsPermission(let tool):
            return (String(localized: "\(agentTitle): Claude espera tu permiso"), String(localized: "Quiere usar \(tool). Ábrelo para permitir o denegar."))
        case .finished(_, _, true):
            return nil
        case .finished(let summary, let isError, _):
            let body = summary.map { String($0.prefix(180)) } ?? (isError ? String(localized: "Terminó con un error.") : String(localized: "Terminó la tarea."))
            return (String(localized: "\(agentTitle): \(isError ? "Claude terminó con error" : "Claude terminó")"), body)
        }
    }
}

/// Lo que importa de una línea del log, aunque venga recortada. Primero se intenta
/// decodificar entera; si no es JSON válido, se extraen los campos con expresiones
/// tolerantes (las comillas de dentro de las cadenas JSON van escapadas, así que
/// `"type":"…"` literal es siempre una clave).
struct AgentLogLineSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case permissionRequest
        case permissionAnswered
        case permissionCancel
        case result
        case userPrompt
        case other
    }

    let kind: Kind
    var requestID: String?
    var toolName: String?
    var displayName: String?
    var isError = false
    var resultText: String?
    /// `result` con `subtype` `AgentTranscriptSeed.closingSubtype` (cierre de un log sembrado).
    var isSeed = false

    /// `nil` si la línea no tiene ni un `type` reconocible.
    init?(line: String) {
        if let event = AgentProtocol.decode(line: line) {
            self.init(event: event)
        } else if let type = Self.firstString(after: "\"type\":", in: line) {
            self.init(type: type, cutLine: line)
        } else {
            return nil
        }
    }

    /// Lectura tolerante de una línea que no es JSON válido (recortada).
    private init(type: String, cutLine line: String) {
        switch type {
        case "control_request":
            // Solo cuentan los permisos (otras peticiones de control no esperan al usuario).
            guard line.contains("\"can_use_tool\"") || !line.contains("\"subtype\":") else {
                kind = .other
                return
            }
            kind = .permissionRequest
            requestID = Self.firstString(after: "\"request_id\":", in: line)
            toolName = Self.firstString(after: "\"tool_name\":", in: line)
            displayName = Self.firstString(after: "\"display_name\":", in: line)
        case PersistentAgentScript.answeredEventType:
            kind = .permissionAnswered
            requestID = Self.firstString(after: "\"request_id\":", in: line)
        case "control_cancel_request":
            kind = .permissionCancel
            requestID = Self.firstString(after: "\"request_id\":", in: line)
        case "result":
            kind = .result
            isError = line.contains("\"is_error\":true")
            resultText = Self.firstString(after: "\"result\":", in: line)
            isSeed = Self.firstString(after: "\"subtype\":", in: line) == AgentTranscriptSeed.closingSubtype
        case "user":
            // Recortada no se sabe si es un prompt o un resultado de herramienta: los
            // resultados llevan `tool_result` cerca del principio.
            let isToolResult = line.contains("\"tool_result\"") || line.contains("\"tool_use_id\"")
            let isSecondary = line.contains("\"isMeta\":true") || line.contains("\"isSynthetic\":true")
            kind = isToolResult || isSecondary ? .other : .userPrompt
        default:
            kind = .other
        }
    }

    private init(event: AgentStreamEvent) {
        switch event {
        case .permissionRequest(let request):
            kind = .permissionRequest
            requestID = request.id
            toolName = request.toolName
            displayName = request.displayName
        case .permissionCancel(let id):
            kind = .permissionCancel
            requestID = id
        case .result(let result):
            kind = .result
            isError = result.isError
            resultText = result.text
            isSeed = result.subtype == AgentTranscriptSeed.closingSubtype
        case .user(let blocks) where blocks.contains(where: { if case .text = $0 { return true } else { return false } }):
            kind = .userPrompt
        default:
            kind = .other
        }
    }

    /// Valor de cadena que sigue a `key` (p. ej. `"type":`), tolerando espacios y
    /// desescapando lo básico. `nil` si no aparece o la cadena está cortada.
    static func firstString(after key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: key) else { return nil }
        var index = keyRange.upperBound
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        guard index < line.endIndex, line[index] == "\"" else { return nil }
        index = line.index(after: index)
        var value = ""
        var escaping = false
        while index < line.endIndex {
            let character = line[index]
            if escaping {
                switch character {
                case "n": value.append("\n")
                case "t": value.append("\t")
                default: value.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }
        return nil
    }
}

/// Instantánea de un agente para los avisos: tamaño del log y su final.
struct AgentLogSnapshot: Equatable, Sendable {
    let id: String
    let isAlive: Bool
    /// Bytes ABSOLUTOS del log (incluidos los rotados).
    let logBytes: Int
    let title: String
    let createdAt: Date
    let tail: String
    /// Carpeta del agente (para que su aviso abra su chat). Vacía si no se sabe.
    var workingDirectory: String = ""
}

extension PersistentAgentScript {

    /// Líneas del final del log que bastan para saber el estado.
    static let attentionTailLines = 30
    /// Cada línea se recorta a esto (un permiso de un `Write` puede ocupar cientos de KB).
    static let attentionLineBytes = 400

    /// Recorta las últimas líneas del log: si una lleva `tool_name` lejos del principio,
    /// se conserva su comienzo (tipo, `request_id`) y ese campo; después se corta a
    /// `attentionLineBytes`. (`.{1,200}`: los `sed` BSD no admiten repeticiones > 255.)
    static func attentionTail(_ file: String) -> String {
        "tail -n \(attentionTailLines) \(file) 2>/dev/null "
            + "| sed -E '/\"tool_name\":\"/ s/^(.{1,200}).*(\"tool_name\":\"[^\"]*\").*$/\\1 \\2/' "
            + "| cut -c 1-\(attentionLineBytes)"
    }

    /// Una línea por agente: `id|vivo|bytes|meta en base64|final recortado en base64`.
    static func snapshots() -> String {
        """
        for d in "$HOME/\(rootRelativePath)"/*/; do \
        [ -f "$d/meta.json" ] || continue; \
        id=$(basename "$d"); p=$(cat "$d/pid" 2>/dev/null); alive=0; \
        [ -n "$p" ] && ps -o args= -p "$p" 2>/dev/null | grep -q -- "$id" && alive=1; \
        size=$(wc -c < "$d/out.ndjson" 2>/dev/null | tr -d ' '); \
        \(absoluteSize); \
        printf '%s|%s|%s|' "$id" "$alive" "$size"; \
        base64 < "$d/meta.json" | tr -d '\\n'; printf '|'; \
        \(attentionTail("\"$d/out.ndjson\"")) | base64 | tr -d '\\n'; echo; \
        done
        """
    }

    static func parseSnapshots(_ output: String) -> [AgentLogSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, isValidID(fields[0]),
                  let metaData = Data(base64Encoded: fields[3]),
                  let meta = try? JSONDecoder.projects.decode(PersistentAgentMeta.self, from: metaData)
            else { return nil }
            let tail = Data(base64Encoded: fields[4]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return AgentLogSnapshot(id: fields[0], isAlive: fields[1] == "1", logBytes: Int(fields[2]) ?? 0,
                                    title: meta.title, createdAt: meta.createdAt, tail: tail,
                                    workingDirectory: meta.workingDirectory)
        }
    }
}

/// Decide qué avisar comparando con lo ya visto (tamaño del log por agente): solo se
/// avisa de lo NUEVO, una vez.
enum AgentAttentionPlanner {
    struct Notice: Equatable, Sendable {
        let agentID: String
        let title: String
        let body: String
    }

    /// Un agente nunca visto pero creado hace menos de esto se considera nuevo (se avisa
    /// de lo que haya hecho); uno más viejo solo se toma como referencia.
    static let recentAgentWindow: TimeInterval = 24 * 3600

    /// `seenBytes`: lo ya visto de los agentes de UN servidor.
    static func notices(
        snapshots: [AgentLogSnapshot],
        seenBytes: [String: Int],
        now: Date = Date()
    ) -> (notices: [Notice], seen: [String: Int]) {
        var notices: [Notice] = []
        var seen = seenBytes
        for snapshot in snapshots {
            let isRecent = now.timeIntervalSince(snapshot.createdAt) < recentAgentWindow
            guard let previous = seenBytes[snapshot.id] ?? (isRecent ? 0 : nil),
                  snapshot.logBytes > previous else {
                seen[snapshot.id] = snapshot.logBytes
                continue
            }
            let attention = AgentAttention.evaluate(logTail: snapshot.tail)
            // Lo que no se pudo evaluar se deja SIN ver: el próximo refresco lo reintenta.
            guard attention != .undetermined else { continue }
            seen[snapshot.id] = snapshot.logBytes
            if let text = attention.notification(agentTitle: snapshot.title) {
                notices.append(Notice(agentID: snapshot.id, title: text.title, body: text.body))
            }
        }
        // Olvidar agentes que ya no existen.
        let present = Set(snapshots.map(\.id))
        seen = seen.filter { present.contains($0.key) }
        return (notices, seen)
    }
}
