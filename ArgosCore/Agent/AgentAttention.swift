//
//  AgentAttention.swift
//  Argos
//
//  ¿Necesita un agente persistente tu atención? Se decide leyendo el FINAL de su log
//  (lógica pura): pide permiso si hay un `control_request` sin responder, o terminó si
//  lo último relevante es un `result`. Lo usan los avisos en segundo plano del iPhone.
//

import Foundation

enum AgentAttention: Equatable, Sendable {
    case none
    case needsPermission(tool: String)
    case finished(summary: String?, isError: Bool)

    /// Estado del agente según las últimas líneas de su log.
    static func evaluate(logTail: String) -> AgentAttention {
        var pending: AgentPermissionRequest?
        var outcome: AgentAttention = .none
        // La primera línea puede venir cortada (es un trozo del final): se ignora si no
        // parsea, igual que cualquier ruido.
        for line in logTail.split(whereSeparator: \.isNewline) {
            guard let event = AgentProtocol.decode(line: String(line)) else { continue }
            switch event {
            case .permissionRequest(let request):
                pending = request
                outcome = .none
            case .permissionCancel(let id):
                if pending?.id == id { pending = nil }
            case .result(let result):
                pending = nil
                outcome = .finished(summary: result.text, isError: result.isError)
            case .user(let blocks) where blocks.contains(where: { if case .text = $0 { return true } else { return false } }):
                outcome = .none // un prompt nuevo: vuelve a trabajar
            default:
                break
            }
        }
        if let pending { return .needsPermission(tool: pending.displayName ?? pending.toolName) }
        return outcome
    }

    /// Texto breve para una notificación (o `nil` si no hay nada que avisar).
    func notification(agentTitle: String) -> (title: String, body: String)? {
        switch self {
        case .none:
            return nil
        case .needsPermission(let tool):
            return ("\(agentTitle): Claude espera tu permiso", "Quiere usar \(tool). Ábrelo para permitir o denegar.")
        case .finished(let summary, let isError):
            let body = summary.map { String($0.prefix(180)) } ?? (isError ? "Terminó con un error." : "Terminó la tarea.")
            return ("\(agentTitle): \(isError ? "Claude terminó con error" : "Claude terminó")", body)
        }
    }
}

/// Instantánea de un agente para los avisos: tamaño del log y su final.
struct AgentLogSnapshot: Equatable, Sendable {
    let id: String
    let isAlive: Bool
    let logBytes: Int
    let title: String
    let createdAt: Date
    let tail: String
}

extension PersistentAgentScript {

    /// Bytes del final del log que bastan para saber el estado.
    static let attentionTailBytes = 16_384

    /// Una línea por agente: `id|vivo|bytes|título en base64|final del log en base64`.
    static func snapshots() -> String {
        """
        for d in "$HOME/\(rootRelativePath)"/*/; do \
        [ -f "$d/meta.json" ] || continue; \
        id=$(basename "$d"); p=$(cat "$d/pid" 2>/dev/null); alive=0; \
        [ -n "$p" ] && ps -o args= -p "$p" 2>/dev/null | grep -q -- "$id" && alive=1; \
        size=$(wc -c < "$d/out.ndjson" 2>/dev/null | tr -d ' '); \
        printf '%s|%s|%s|' "$id" "$alive" "${size:-0}"; \
        base64 < "$d/meta.json" | tr -d '\\n'; printf '|'; \
        tail -c \(attentionTailBytes) "$d/out.ndjson" 2>/dev/null | base64 | tr -d '\\n'; echo; \
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
                                    title: meta.title, createdAt: meta.createdAt, tail: tail)
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
            defer { seen[snapshot.id] = snapshot.logBytes }
            let isRecent = now.timeIntervalSince(snapshot.createdAt) < recentAgentWindow
            guard let previous = seenBytes[snapshot.id] ?? (isRecent ? 0 : nil),
                  snapshot.logBytes > previous else { continue }
            let attention = AgentAttention.evaluate(logTail: snapshot.tail)
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
