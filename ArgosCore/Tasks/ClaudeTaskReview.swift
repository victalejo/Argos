//
//  ClaudeTaskReview.swift
//  ArgosCore
//
//  Informe del revisor automático antes del push (`review.json` del encargo, ver
//  `ClaudeTaskReviewScript`). Lógica pura. Lo escribe un `claude` en el servidor: no es de
//  fiar, así que se lee con tolerancia (campos que faltan o raros) y con topes de tamaño.
//

import Foundation

struct ClaudeTaskReview: Equatable, Sendable {

    enum Verdict: String, Equatable, Sendable {
        case approve
        case block
        /// No se pudo saber (JSON roto, plazo vencido, `claude` que no arranca): bloquea.
        case inconclusive
    }

    enum Severity: String, Equatable, Sendable, Comparable, CaseIterable {
        case low, medium, high, critical

        private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }

        var label: String {
            switch self {
            case .low: return String(localized: "Baja")
            case .medium: return String(localized: "Media")
            case .high: return String(localized: "Alta")
            case .critical: return String(localized: "Crítica")
            }
        }
    }

    struct Finding: Equatable, Sendable, Identifiable {
        let id: Int
        let severity: Severity?
        let category: String
        let file: String?
        let line: Int?
        let message: String

        /// «Ruta:12» (o solo la ruta), para enseñarlo junto al hallazgo.
        var location: String? {
            guard let file, !file.isEmpty else { return nil }
            return line.map { "\(file):\($0)" } ?? file
        }
    }

    let verdict: Verdict?
    let summary: String
    /// Por qué no fue concluyente (`timeout`, `invalid`, `no-claude`, `error`).
    let cause: String?
    let findings: [Finding]
    /// El informe no cabía en el listado: el completo está en `review.md` en el servidor.
    var truncated = false

    static let maxFindings = 50
    static let maxText = 1_000

    /// Hallazgos de más a menos graves.
    var sortedFindings: [Finding] {
        findings.sorted { ($0.severity ?? .low) > ($1.severity ?? .low) }
    }

    /// Texto de la causa de una revisión no concluyente.
    var causeText: String? {
        guard verdict == .inconclusive || verdict == nil else { return nil }
        switch cause {
        case "timeout": return String(localized: "El revisor no respondió a tiempo.")
        case "invalid": return String(localized: "La respuesta del revisor no se pudo leer.")
        case "no-claude": return String(localized: "No se encontró claude en el servidor.")
        case "truncated": return String(localized: "El cambio es demasiado grande: el revisor no lo vio entero y no se subió.")
        case "held": return String(localized: "Incluye un commit que el revisor bloqueó en otro encargo: resuelve ese primero.")
        case "empty": return String(localized: "No había cambios que revisar.")
        case "diff": return String(localized: "No se pudo obtener el cambio para revisarlo.")
        default: return String(localized: "El revisor no pudo ejecutarse.")
        }
    }

    /// Lee `review.json`; `nil` si no es un objeto JSON.
    static func parse(_ text: String) -> ClaudeTaskReview? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let raw = (object["findings"] as? [Any] ?? []).prefix(maxFindings)
        let findings = raw.enumerated().compactMap { index, value -> Finding? in
            guard let item = value as? [String: Any] else { return nil }
            let message = clip(item["message"] as? String ?? "")
            guard !message.isEmpty else { return nil }
            return Finding(
                id: index,
                severity: (item["severity"] as? String).flatMap { Severity(rawValue: $0.lowercased()) },
                category: clip(item["category"] as? String ?? "", to: 40),
                file: (item["file"] as? String).map { clip($0, to: 300) },
                line: (item["line"] as? Int) ?? (item["line"] as? String).flatMap(Int.init),
                message: message
            )
        }
        var review = ClaudeTaskReview(
            verdict: (object["verdict"] as? String).flatMap(Verdict.init(rawValue:)),
            summary: clip(object["summary"] as? String ?? ""),
            cause: (object["cause"] as? String).map { clip($0, to: 40) },
            findings: findings
        )
        review.truncated = object["truncated"] as? Bool ?? false
        return review
    }

    private static func clip(_ text: String, to limit: Int = maxText) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

/// Un encargo que el revisor dejó en pausa, tal como lo trae el sondeo (para la bandeja).
struct ClaudeTaskReviewBlock: Equatable, Sendable, Hashable {
    let projectKey: String
    let folder: String
    let title: String

    var id: String { "\(projectKey)/\(folder)" }

    /// Líneas `<proyecto>/<encargo>|<título>` de `ClaudeTaskReviewScript.pollCommand`.
    static func parse(lines: [String]) -> [ClaudeTaskReviewBlock] {
        lines.compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let path = parts.first.map { $0.split(separator: "/") } ?? []
            guard path.count == 2, isSafe(path[0]), isSafe(path[1]) else { return nil }
            let title = parts.count > 1 ? String(parts[1].prefix(200)) : ""
            return ClaudeTaskReviewBlock(projectKey: String(path[0]), folder: String(path[1]), title: title)
        }
    }

    private static func isSafe(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
