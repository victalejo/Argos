//
//  ClaudeOrphans.swift
//  ArgosCore
//
//  Procesos de Claude huérfanos (lógica pura): `claude` que ya no cuelga de ningún panel de
//  tmux ni es un agente persistente, y que sigue ocupando memoria con sus hijos (MCP, node…).
//  Pasa tras un OOM o al cerrarse mal un terminal. Se parsea el listado de
//  `ClaudeOrphanScript.listCommand` y se decide aquí; el script de matar vuelve a
//  comprobarlo TODO en el servidor justo antes de cada señal.
//

import Foundation

/// Fila de la tabla de procesos del servidor.
struct ServerProcessRow: Equatable, Sendable {
    let pid: Int
    let ppid: Int
    let uid: Int
    let rssKB: Int
    let elapsedSeconds: Int?
    /// Terminal (`?` o `??` si no tiene).
    let tty: String
    /// Nombre corto (sin ruta).
    let name: String
}

/// Un `claude` huérfano y lo que cuelga de él.
struct ClaudeOrphan: Equatable, Sendable, Identifiable {
    let pid: Int
    /// Memoria del proceso y de todos sus descendientes.
    let totalRSSKB: Int
    let descendants: Int
    let elapsedSeconds: Int?
    /// Terminal, si aún tiene una (`nil` si no).
    let tty: String?
    /// Hora de arranque tal como la da `ps -o lstart=`: identifica el proceso al matarlo
    /// (un PID puede reutilizarse).
    let fingerprint: String

    var id: Int { pid }
}

/// Lo que el servidor contó para buscar huérfanos.
struct ClaudeProcessSurvey: Equatable, Sendable {
    var uid: Int?
    var processes: [ServerProcessRow] = []
    /// PIDs de los paneles de tmux.
    var panePIDs: Set<Int> = []
    /// PIDs de agentes persistentes registrados (vivos y comprobados).
    var agentPIDs: Set<Int> = []
    var fingerprints: [Int: String] = [:]

    /// Ancestros cuyo árbol nunca se toca: un servidor tmux (paneles de cualquier socket),
    /// una sesión SSH viva (agente de la app, terminal sin tmux) o mosh.
    static let protectedAncestorPrefixes = ["tmux", "sshd", "mosh-server"]
    static let claudeName = "claude"
    private static let maxDepth = 64

    static func parse(_ output: String) -> ClaudeProcessSurvey {
        var survey = ClaudeProcessSurvey()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch fields.first {
            case "@@me": survey.uid = fields.count > 1 ? Int(fields[1]) : nil
            case "pane": if fields.count > 1, let pid = positive(fields[1]) { survey.panePIDs.insert(pid) }
            case "agent": if fields.count > 1, let pid = positive(fields[1]) { survey.agentPIDs.insert(pid) }
            case "start":
                if fields.count > 2, let pid = positive(fields[1]),
                   let print = ClaudeOrphanScript.validFingerprint(fields[2...].joined(separator: " ")) {
                    survey.fingerprints[pid] = print
                }
            case "p":
                if let row = parseRow(fields) { survey.processes.append(row) }
            default:
                continue
            }
        }
        return survey
    }

    private static func positive(_ text: String) -> Int? {
        guard let value = Int(text), value > 0, value < 1 << 32 else { return nil }
        return value
    }

    /// `p <pid> <ppid> <uid> <rss> <etime> <tty> <comm…>`.
    private static func parseRow(_ fields: [String]) -> ServerProcessRow? {
        guard fields.count >= 8, let pid = positive(fields[1]), let ppid = Int(fields[2]), ppid >= 0,
              let uid = Int(fields[3]), uid >= 0, let rss = Int(fields[4]), (0...ServerResourceParser.maxCounter).contains(rss)
        else { return nil }
        let command = fields[7...].joined(separator: " ")
        let name = command.split(separator: "/").last.map(String.init) ?? command
        return ServerProcessRow(
            pid: pid, ppid: ppid, uid: uid, rssKB: rss,
            elapsedSeconds: parseElapsed(fields[5]), tty: fields[6], name: name
        )
    }

    /// `[[dd-]hh:]mm:ss` de `ps -o etime`.
    static func parseElapsed(_ text: String) -> Int? {
        let dayParts = text.split(separator: "-", maxSplits: 1).map(String.init)
        var days = 0
        var clock = text
        if dayParts.count == 2 {
            guard let value = Int(dayParts[0]), (0...100_000).contains(value) else { return nil }
            days = value
            clock = dayParts[1]
        }
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        let values = parts.compactMap { $0 }
        guard (2...3).contains(parts.count), values.count == parts.count,
              values.allSatisfy({ (0..<100).contains($0) })
        else { return nil }
        let seconds = values.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }

    // MARK: - Detección

    /// Huérfanos del usuario, de más a menos memoria.
    func orphans() -> [ClaudeOrphan] {
        guard let uid else { return [] }
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int: [Int]] = [:]
        for row in processes where row.ppid != row.pid { children[row.ppid, default: []].append(row.pid) }

        let candidates = processes.filter { row in
            row.uid == uid && row.name == Self.claudeName && fingerprints[row.pid] != nil
                && !isProtected(row.pid, byPID: byPID)
        }
        let candidatePIDs = Set(candidates.map(\.pid))
        // Solo la raíz: un `claude` hijo de otro huérfano va con él.
        let roots = candidates.filter { !hasAncestor(in: candidatePIDs, from: $0.pid, byPID: byPID) }
        return roots.map { root in
            let family = descendants(of: root.pid, children: children)
            let rss = family.reduce(root.rssKB) { $0 + (byPID[$1]?.rssKB ?? 0) }
            let tty = root.tty.allSatisfy({ $0 == "?" || $0 == "-" }) ? nil : root.tty
            return ClaudeOrphan(
                pid: root.pid, totalRSSKB: rss, descendants: family.count,
                elapsedSeconds: root.elapsedSeconds, tty: tty, fingerprint: fingerprints[root.pid] ?? ""
            )
        }
        .sorted { $0.totalRSSKB != $1.totalRSSKB ? $0.totalRSSKB > $1.totalRSSKB : $0.pid < $1.pid }
    }

    /// El proceso o un ancestro es un panel de tmux, un agente o un proceso protegido. Si
    /// la cadena no llega a init (tabla incompleta o con ciclos), se trata como protegido.
    func isProtected(_ pid: Int, byPID: [Int: ServerProcessRow]) -> Bool {
        var current = pid
        for depth in 0..<Self.maxDepth {
            if panePIDs.contains(current) || agentPIDs.contains(current) { return true }
            guard let row = byPID[current] else { return true }
            if depth > 0, Self.protectedAncestorPrefixes.contains(where: { row.name.hasPrefix($0) }) { return true }
            if row.ppid <= 1 { return false }
            current = row.ppid
        }
        return true
    }

    private func hasAncestor(in set: Set<Int>, from pid: Int, byPID: [Int: ServerProcessRow]) -> Bool {
        var current = byPID[pid]?.ppid ?? 0
        for _ in 0..<Self.maxDepth {
            if current <= 1 { return false }
            if set.contains(current) { return true }
            guard let next = byPID[current]?.ppid else { return false }
            current = next
        }
        return false
    }

    private func descendants(of pid: Int, children: [Int: [Int]]) -> [Int] {
        var result: [Int] = []
        var seen: Set<Int> = [pid]
        var queue = children[pid] ?? []
        while let next = queue.popLast(), result.count < 10_000 {
            guard seen.insert(next).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }
}

/// Resultado de intentar matar un huérfano.
enum ClaudeOrphanKillOutcome: String, Equatable, Sendable {
    /// Terminó (con TERM o con KILL).
    case killed
    /// Ya no estaba, o había cambiado (otro proceso con ese PID, o ya no es huérfano): no se tocó.
    case skipped
    /// Sigue vivo tras KILL.
    case stuck
}
