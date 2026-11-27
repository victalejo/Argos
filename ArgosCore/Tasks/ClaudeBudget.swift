//
//  ClaudeBudget.swift
//  ArgosCore
//
//  Presupuesto por proyecto (lógica pura; ver `docs/encargos.md`): dos topes opcionales y
//  combinables que frenan la cola de encargos y las tareas programadas de un proyecto:
//
//  - **% de la ventana de 5 h**: lo que el proyecto lleva gastado en la ventana actual se
//    estima como `used_percentage global × coste del proyecto / coste de todos`, contando
//    las horas del índice de uso desde `resets_at − 5 h`. Sin la statusline de límites no
//    se puede evaluar (no frena).
//  - **Máximo al día** en coste equivalente (USD, `ClaudePricing`), desde la medianoche del
//    servidor.
//
//  El despachador hace la misma cuenta en awk (`ClaudeBudgetScript`); los tests comprueban
//  que ambos coinciden.
//

import Foundation

/// Topes de un proyecto, guardados en el servidor (`~/.config/argos/budgets/<proyecto>`).
struct ClaudeProjectBudget: Equatable, Sendable {
    /// Porcentaje de la ventana de 5 h que puede gastar el proyecto (1…100).
    var windowPercent: Int?
    /// Coste equivalente máximo al día (USD).
    var dailyUSD: Double?
    /// Versión del formato leído: con una más nueva que la que entiende, la app no escribe.
    var version = ClaudeProjectBudget.formatVersion

    static let formatVersion = 1
    static let windowRange = 1...100
    static let dailyRange = 0.01...100_000.0

    var isEmpty: Bool { windowPercent == nil && dailyUSD == nil }
    var isNewerFormat: Bool { version > Self.formatVersion }

    init(windowPercent: Int? = nil, dailyUSD: Double? = nil) {
        self.windowPercent = windowPercent.flatMap { Self.windowRange.contains($0) ? $0 : nil }
        self.dailyUSD = dailyUSD.flatMap { Self.dailyRange.contains($0) ? $0 : nil }
    }

    /// `clave=valor` por línea; claves desconocidas y valores fuera de rango se ignoran.
    init(configText: String) {
        var values: [String: String] = [:]
        for line in configText.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if values[key] == nil {
                values[key] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        self.init(
            windowPercent: values["window_pct"].flatMap { Self.isDigits($0) ? Int($0) : nil },
            dailyUSD: values["daily_usd"].flatMap { Self.isDecimal($0) ? Double($0) : nil }
        )
        version = values["v"].flatMap(Int.init) ?? Self.formatVersion
    }

    /// Lo que se escribe en el servidor (legible por sh: sin espacios ni comillas).
    var configText: String {
        var lines = ["v=\(Self.formatVersion)"]
        if let windowPercent { lines.append("window_pct=\(windowPercent)") }
        if let dailyUSD { lines.append("daily_usd=\(String(format: "%.2f", dailyUSD))") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 3 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Como lo acepta el despachador: `^[0-9]+(\.[0-9]+)?$`.
    private static func isDecimal(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.count <= 12, (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}

/// Uso frente a un tope.
struct ClaudeBudgetMeter: Equatable, Sendable {
    /// Porcentaje de la ventana (tope de ventana) o USD (tope diario).
    let used: Double
    let cap: Double
    /// Cuándo se libera (empieza la ventana o el día siguiente).
    let releasesAt: Date?

    var isExceeded: Bool { used >= cap }
    var fraction: Double { cap > 0 ? min(1, max(0, used / cap)) : 0 }
}

/// Estado del tope de la ventana de 5 h.
enum ClaudeBudgetWindowState: Equatable, Sendable {
    case notSet
    /// Sin datos de la statusline de límites: no se puede evaluar (no frena).
    case unavailable
    case meter(ClaudeBudgetMeter)
}

struct ClaudeBudgetEvaluation: Equatable, Sendable {
    let window: ClaudeBudgetWindowState
    let daily: ClaudeBudgetMeter?

    /// Duración de la ventana corta de Claude.
    static let windowSeconds: TimeInterval = 5 * 3600

    /// Algún tope superado (el de la ventana primero, como el despachador).
    var block: ClaudeBudgetBlock.Kind? {
        if case .meter(let meter) = window, meter.isExceeded { return .window }
        if let daily, daily.isExceeded { return .daily }
        return nil
    }

    /// - Parameters:
    ///   - fiveHour: ventana `five_hour` de la statusline (`nil` si no está puesta).
    ///   - dayStart: medianoche de hoy en la hora local del SERVIDOR.
    static func evaluate(
        _ budget: ClaudeProjectBudget,
        projectKey: String,
        records: [ClaudeUsageRecord],
        fiveHour: ClaudeLimitWindow?,
        now: Date,
        dayStart: Date
    ) -> ClaudeBudgetEvaluation {
        ClaudeBudgetEvaluation(
            window: windowState(budget, projectKey: projectKey, records: records, fiveHour: fiveHour, now: now),
            daily: budget.dailyUSD.map { cap in
                let start = hourFloor(dayStart)
                let spent = cost(of: records, from: start, to: now) { $0 == projectKey }
                return ClaudeBudgetMeter(used: spent, cap: cap, releasesAt: dayStart.addingTimeInterval(86_400))
            }
        )
    }

    private static func windowState(
        _ budget: ClaudeProjectBudget, projectKey: String, records: [ClaudeUsageRecord],
        fiveHour: ClaudeLimitWindow?, now: Date
    ) -> ClaudeBudgetWindowState {
        guard let cap = budget.windowPercent else { return .notSet }
        guard let fiveHour, let resetsAt = fiveHour.resetsAt else { return .unavailable }
        guard resetsAt > now else { return .meter(ClaudeBudgetMeter(used: 0, cap: Double(cap), releasesAt: nil)) }
        // Las filas del índice son horas enteras: cuenta la hora en que empezó la ventana.
        let start = hourFloor(resetsAt.addingTimeInterval(-windowSeconds))
        let all = cost(of: records, from: start, to: now) { _ in true }
        let mine = cost(of: records, from: start, to: now) { $0 == projectKey }
        let used = all > 0 ? fiveHour.usedPercent * mine / all : 0
        return .meter(ClaudeBudgetMeter(used: used, cap: Double(cap), releasesAt: resetsAt))
    }

    private static func cost(of records: [ClaudeUsageRecord], from start: Date, to now: Date, project: (String) -> Bool) -> Double {
        records
            .filter { $0.hour >= start && $0.hour <= now && project($0.projectKey) }
            .reduce(0) { $0 + ClaudePricing.cost(model: $1.model, tokens: $1.tokens) }
    }

    static func hourFloor(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

/// Bloqueo que anota el despachador al no arrancar un encargo
/// (`~/.config/argos/budgets/<proyecto>.blocked`).
struct ClaudeBudgetBlock: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case window
        case daily
    }

    let projectKey: String
    let kind: Kind
    let used: Double
    let cap: Double
    let until: Date
    /// Cuándo empezó este bloqueo (el despachador lo conserva mientras dure): un bloqueo
    /// nuevo en la misma ventana es otro aviso.
    let since: Date?

    var id: String {
        let start = since.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "\(projectKey)|\(kind.rawValue)|\(Int(until.timeIntervalSince1970))|\(start)"
    }

    /// Sigue vigente (pasada su hora, el despachador lo deja arrancar en el siguiente tick).
    func isActive(now: Date) -> Bool { until > now }

    /// Línea del sondeo: `blocked <proyecto> v=1 kind=window used=18.40 cap=20 until=… since=…`.
    init?(pollLine line: String) {
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count >= 3, fields[0] == "blocked", Self.isSafeKey(fields[1]) else { return nil }
        var values: [String: String] = [:]
        for field in fields.dropFirst(2) {
            guard let equals = field.firstIndex(of: "=") else { continue }
            values[String(field[..<equals])] = String(field[field.index(after: equals)...])
        }
        guard values["v"] == "1",
              let kind = values["kind"].flatMap(Kind.init(rawValue:)),
              let used = values["used"].flatMap(Double.init), used.isFinite, used >= 0,
              let cap = values["cap"].flatMap(Double.init), cap.isFinite, cap > 0,
              let until = values["until"].flatMap(Double.init), until > 0
        else { return nil }
        let since = values["since"].flatMap(Double.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        self.init(
            projectKey: fields[1], kind: kind, used: used, cap: cap,
            until: Date(timeIntervalSince1970: until), since: since
        )
    }

    init(projectKey: String, kind: Kind, used: Double, cap: Double, until: Date, since: Date? = nil) {
        self.projectKey = projectKey
        self.kind = kind
        self.used = min(used, 1_000_000_000)
        self.cap = cap
        self.until = until
        self.since = since
    }

    static func isSafeKey(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 255 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// «Pausado por presupuesto: 18 % de 20 % de la ventana de 5 h; se libera a las 15:00.»
    func message(now: Date = Date()) -> String {
        let when = ClaudeLimitsStatus.resetText(until, now: now)
        switch kind {
        case .window:
            let used = String(Int(self.used.rounded()))
            let cap = String(Int(self.cap.rounded()))
            return String(localized: "Pausado por presupuesto: \(used) % de \(cap) % de la ventana de 5 h; se libera \(when).")
        case .daily:
            let used = ClaudeBudgetFormat.usd(self.used)
            let cap = ClaudeBudgetFormat.usd(self.cap)
            return String(localized: "Pausado por presupuesto: \(used) de \(cap) hoy; se libera \(when).")
        }
    }

    /// Lista de la sección `budget` del sondeo.
    static func parse(pollLines lines: [String]) -> [ClaudeBudgetBlock] {
        lines.compactMap(ClaudeBudgetBlock.init(pollLine:))
    }
}

enum ClaudeBudgetFormat {
    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
