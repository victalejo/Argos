//
//  PersistentAgentOverview.swift
//  Argos
//
//  Los agentes persistentes de un servidor con lo justo para listarlos y avisar: si están
//  vivos, en reposo o detenidos, desde cuándo no hacen nada y qué dice el final de su log
//  (trabajando, espera un permiso, terminó). Un solo comando de solo lectura para todos;
//  el análisis es puro y testeable. No cambia nada del formato del servidor: lee lo mismo
//  que `PersistentAgentScript.snapshots()` más la fecha del log.
//

import Foundation

/// Qué hace ahora un agente persistente.
enum PersistentAgentActivity: Equatable, Sendable {
    case working
    case waitingPermission(tool: String)
    /// Vivo y esperando un mensaje (su último turno terminó).
    case idle
    /// En reposo (hibernado): escribirle lo reanuda.
    case asleep
    case stopped

    var title: String {
        switch self {
        case .working: return "Trabajando"
        case .waitingPermission: return "Espera tu permiso"
        case .idle: return "Esperando"
        case .asleep: return "En reposo"
        case .stopped: return "Detenido"
        }
    }

    var systemImage: String {
        switch self {
        case .working: return "sparkles"
        case .waitingPermission: return "hand.raised.fill"
        case .idle: return "checkmark.circle"
        case .asleep: return "moon.zzz"
        case .stopped: return "stop.circle"
        }
    }
}

struct PersistentAgentOverview: Identifiable, Equatable, Sendable {
    let id: String
    let isAlive: Bool
    /// Bytes ABSOLUTOS del log (incluidos los rotados).
    let logBytes: Int
    /// Segundos desde la última escritura en el log (`nil` si no se sabe).
    let idleSeconds: Int?
    let meta: PersistentAgentMeta
    /// Lo que dice el final del log.
    let attention: AgentAttention

    var info: PersistentAgentInfo {
        PersistentAgentInfo(id: id, isAlive: isAlive, logBytes: logBytes, meta: meta)
    }

    var activity: PersistentAgentActivity {
        guard isAlive else { return meta.isHibernated ? .asleep : .stopped }
        switch attention {
        case .needsPermission(let tool): return .waitingPermission(tool: tool)
        case .finished: return .idle
        case .none: return logBytes > 0 ? .working : .idle
        case .undetermined: return .working
        }
    }

    /// Fecha aproximada de la última actividad.
    func lastActivity(now: Date = Date()) -> Date? {
        idleSeconds.map { now.addingTimeInterval(-TimeInterval($0)) }
    }
}

extension PersistentAgentScript {

    /// Una línea por agente:
    /// `id|vivo|bytes|segundos inactivo|meta en base64|final recortado en base64`.
    static func overview() -> String {
        """
        now=$(date +%s); \
        for d in "$HOME/\(rootRelativePath)"/*/; do \
        [ -f "$d/meta.json" ] || continue; \
        id=$(basename "$d"); p=$(cat "$d/pid" 2>/dev/null); alive=0; \
        [ -n "$p" ] && ps -o args= -p "$p" 2>/dev/null | grep -q -- "$id" && alive=1; \
        size=$(wc -c < "$d/out.ndjson" 2>/dev/null | tr -d ' '); \
        \(absoluteSize); \
        \(PersistentAgentShell.modificationTime("\"$d/out.ndjson\"")); idle=$(( now - ${m:-$now} )); \
        printf '%s|%s|%s|%s|' "$id" "$alive" "$size" "$idle"; \
        base64 < "$d/meta.json" | tr -d '\\n'; printf '|'; \
        \(attentionTail("\"$d/out.ndjson\"")) | base64 | tr -d '\\n'; echo; \
        done; true
        """
    }

    static func parseOverview(_ output: String) -> [PersistentAgentOverview] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, isValidID(fields[0]),
                  let metaData = Data(base64Encoded: fields[4]),
                  let meta = try? JSONDecoder.projects.decode(PersistentAgentMeta.self, from: metaData)
            else { return nil }
            let tail = Data(base64Encoded: fields[5]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return PersistentAgentOverview(
                id: fields[0].lowercased(),
                isAlive: fields[1] == "1",
                logBytes: Int(fields[2]) ?? 0,
                idleSeconds: Int(fields[3]).map { max(0, $0) },
                meta: meta,
                attention: AgentAttention.evaluate(logTail: tail)
            )
        }
        .sorted { $0.meta.createdAt > $1.meta.createdAt }
    }
}

extension SSHServicing {
    /// Agentes persistentes del servidor con su estado (un viaje SSH).
    func persistentAgentOverview() async throws -> [PersistentAgentOverview] {
        PersistentAgentScript.parseOverview(try await runAgentScript(PersistentAgentScript.overview()))
    }
}

/// Carpetas comparables (sin barra final; `~/x` y `$HOME/x` no se igualan aquí).
enum AgentFolderMatch {
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    static func normalized(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
