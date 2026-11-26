//
//  ClaudeUsage.swift
//  ArgosCore
//
//  Uso de tokens de Claude Code (lógica pura): lee el agregado del índice del servidor
//  (`ClaudeUsageIndex`), calcula el coste equivalente en precios de la API y lo resume por
//  rango, proyecto, día y modelo. Con suscripción no se paga por token: el coste sirve para
//  comparar proyectos y días, no es una factura.
//

import Foundation

/// Una fila del ledger: una hora (UTC), un proyecto y un modelo.
struct ClaudeUsageRecord: Equatable, Sendable {
    let hour: Date
    /// Carpeta de Claude Code del proyecto (su ruta con `/` y `.` cambiados por `-`).
    let projectKey: String
    let model: String
    let tokens: ClaudeTokenCounts
    let requests: Int

    /// `hora<TAB>proyecto<TAB>modelo<TAB>entrada<TAB>salida<TAB>cache5m<TAB>cache1h<TAB>lectura<TAB>peticiones`
    init?(ledgerLine line: String) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 9, let hour = Self.parseHour(fields[0]) else { return nil }
        let numbers = fields[3...8].compactMap { Int($0) }
        guard numbers.count == 6 else { return nil }
        self.hour = hour
        self.projectKey = fields[1]
        self.model = fields[2]
        self.tokens = ClaudeTokenCounts(
            input: numbers[0], output: numbers[1], cacheWrite5m: numbers[2], cacheWrite1h: numbers[3], cacheRead: numbers[4]
        )
        self.requests = numbers[5]
    }

    init(hour: Date, projectKey: String, model: String, tokens: ClaudeTokenCounts, requests: Int) {
        self.hour = hour
        self.projectKey = projectKey
        self.model = model
        self.tokens = tokens
        self.requests = requests
    }

    /// `AAAA-MM-DDTHH` en UTC.
    static func parseHour(_ text: String) -> Date? {
        let parts = text.split(separator: "T")
        guard parts.count == 2, let hour = Int(parts[1]), (0..<24).contains(hour) else { return nil }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        guard day.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2], hour: hour))
    }
}

struct ClaudeTokenCounts: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (lhs: Self, rhs: Self) -> Self {
        ClaudeTokenCounts(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m, cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}

/// Precios por millón de tokens (USD) de la API de Anthropic.
struct ClaudeModelPrice: Equatable, Sendable {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double

    /// Regla general: escritura de caché 1,25× (5 min) o 2× (1 h) y lectura 0,1× la entrada.
    static func standard(input: Double, output: Double, cacheRead: Double? = nil) -> ClaudeModelPrice {
        ClaudeModelPrice(
            input: input, output: output, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2,
            cacheRead: cacheRead ?? input * 0.1
        )
    }

    func cost(_ tokens: ClaudeTokenCounts) -> Double {
        (Double(tokens.input) * input + Double(tokens.output) * output
            + Double(tokens.cacheWrite5m) * cacheWrite5m + Double(tokens.cacheWrite1h) * cacheWrite1h
            + Double(tokens.cacheRead) * cacheRead) / 1_000_000
    }
}

enum ClaudePricing {

    /// Prefijo del id del modelo → precio. Se elige el prefijo MÁS LARGO que encaje (así
    /// `claude-opus-5-5` no cae en `claude-opus-5`). Precios de noviembre de 2026.
    static let table: [(prefix: String, price: ClaudeModelPrice)] = [
        ("claude-fable-5-2", ClaudeModelPrice(input: 8, output: 40, cacheWrite5m: 10, cacheWrite1h: 16, cacheRead: 0.20)),
        ("claude-mythos-5-2", ClaudeModelPrice(input: 8, output: 40, cacheWrite5m: 10, cacheWrite1h: 16, cacheRead: 0.20)),
        ("claude-fable-5-1", .standard(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", .standard(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", .standard(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", .standard(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", ClaudeModelPrice(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20)),
        ("claude-opus-5", .standard(input: 5, output: 25)),
        ("claude-opus-4-8", .standard(input: 5, output: 25)),
        ("claude-opus-4-7", .standard(input: 5, output: 25)),
        ("claude-opus-4-6", .standard(input: 5, output: 25)),
        ("claude-opus-4-5", .standard(input: 5, output: 25)),
        ("claude-opus-4", .standard(input: 15, output: 75)),
        ("claude-sonnet-5-5", ClaudeModelPrice(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.10)),
        ("claude-sonnet-5", .standard(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", .standard(input: 3, output: 15)),
        ("claude-haiku-5-5", .standard(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("claude-haiku-4-5", .standard(input: 1, output: 5)),
    ]

    /// `nil` para modelos desconocidos o sintéticos (`<synthetic>`): no suman coste.
    static func price(for model: String) -> ClaudeModelPrice? {
        table.filter { model.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.price
    }

    static func cost(model: String, tokens: ClaudeTokenCounts) -> Double {
        price(for: model)?.cost(tokens) ?? 0
    }
}

/// Estado del índice en el servidor.
enum ClaudeUsageIndexStatus: Equatable, Sendable {
    /// Nunca se ha calculado.
    case never
    case running(since: Date?)
    case done(at: Date)
}

/// Lo leído del servidor: estado del índice y filas.
struct ClaudeUsageSnapshot: Equatable, Sendable {
    let status: ClaudeUsageIndexStatus
    let records: [ClaudeUsageRecord]

    /// Salida de `ClaudeUsageIndex.readCommand`.
    init(output: String) {
        var statusLine = ""
        var running = false
        var records: [ClaudeUsageRecord] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("status ") {
                statusLine = String(line.dropFirst(7))
            } else if line == "status" {
                statusLine = ""
            } else if line == "running" {
                running = true
            } else if let record = ClaudeUsageRecord(ledgerLine: line) {
                records.append(record)
            }
        }
        let fields = statusLine.split(separator: " ")
        let stamp = fields.count > 1 ? Double(fields[1]).map { Date(timeIntervalSince1970: $0) } : nil
        if running || fields.first == "running" {
            status = .running(since: stamp)
        } else if fields.first == "done", let stamp {
            status = .done(at: stamp)
        } else {
            status = .never
        }
        self.records = records
    }

    init(status: ClaudeUsageIndexStatus, records: [ClaudeUsageRecord]) {
        self.status = status
        self.records = records
    }
}

/// Periodo que se resume.
enum ClaudeUsageRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return String(localized: "Hoy")
        case .week: return String(localized: "7 días")
        case .month: return String(localized: "30 días")
        }
    }

    /// Inicio del periodo en el calendario local (hoy cuenta como uno de los días).
    func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let days: Int
        switch self {
        case .today: days = 0
        case .week: days = 6
        case .month: days = 29
        }
        return calendar.date(byAdding: .day, value: -days, to: today) ?? today
    }
}

/// Una línea de resumen (proyecto o modelo).
struct ClaudeUsageLine: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let tokens: ClaudeTokenCounts
    let cost: Double
    let requests: Int
}

/// Un día para la gráfica.
struct ClaudeUsageDay: Identifiable, Equatable, Sendable {
    let day: Date
    let cost: Double
    let tokens: Int
    var id: Date { day }
}

struct ClaudeUsageSummary: Equatable, Sendable {
    let tokens: ClaudeTokenCounts
    let cost: Double
    let requests: Int
    let projects: [ClaudeUsageLine]
    let models: [ClaudeUsageLine]
    let days: [ClaudeUsageDay]

    /// Resume `records` en `range`. `projectNames` traduce la carpeta de Claude Code al
    /// nombre del proyecto en Argos (si se conoce).
    static func make(
        _ records: [ClaudeUsageRecord],
        range: ClaudeUsageRange,
        projectNames: [String: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ClaudeUsageSummary {
        let start = range.start(now: now, calendar: calendar)
        var total = Accumulator()
        var byProject: [String: Accumulator] = [:]
        var byModel: [String: Accumulator] = [:]
        var byDay: [Date: Accumulator] = [:]
        for record in records where record.hour >= start && record.hour <= now {
            let cost = ClaudePricing.cost(model: record.model, tokens: record.tokens)
            total.add(record, cost: cost)
            byProject[record.projectKey, default: Accumulator()].add(record, cost: cost)
            byModel[record.model, default: Accumulator()].add(record, cost: cost)
            byDay[calendar.startOfDay(for: record.hour), default: Accumulator()].add(record, cost: cost)
        }
        return ClaudeUsageSummary(
            tokens: total.tokens, cost: total.cost, requests: total.requests,
            projects: lines(byProject) { projectNames[$0] ?? ClaudeUsageProjects.fallbackName($0) },
            models: lines(byModel) { $0 },
            days: days(from: start, to: now, values: byDay, calendar: calendar)
        )
    }

    private struct Accumulator {
        var tokens = ClaudeTokenCounts()
        var cost = 0.0
        var requests = 0

        mutating func add(_ record: ClaudeUsageRecord, cost recordCost: Double) {
            tokens = tokens + record.tokens
            cost += recordCost
            requests += record.requests
        }
    }

    private static func lines(_ groups: [String: Accumulator], name: (String) -> String) -> [ClaudeUsageLine] {
        groups.map { key, value in
            ClaudeUsageLine(id: key, name: name(key), tokens: value.tokens, cost: value.cost, requests: value.requests)
        }
        .sorted { ($0.cost, $0.tokens.total, $0.id) > ($1.cost, $1.tokens.total, $1.id) }
    }

    /// Un punto por día del periodo, también los días sin uso.
    private static func days(from start: Date, to now: Date, values: [Date: Accumulator], calendar: Calendar) -> [ClaudeUsageDay] {
        var result: [ClaudeUsageDay] = []
        var day = start
        while day <= now {
            let value = values[day] ?? Accumulator()
            result.append(ClaudeUsageDay(day: day, cost: value.cost, tokens: value.tokens.total))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

enum ClaudeUsageProjects {

    /// Carpeta que usa Claude Code para una ruta: como su `replace(/[^a-zA-Z0-9]/g, "-")` en
    /// JavaScript, cada unidad UTF-16 que no sea letra o número ASCII pasa a `-` (un emoji,
    /// que son dos unidades, da dos guiones).
    static func key(forPath path: String) -> String {
        String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(UnicodeScalar(UInt8(unit)))
            default: return "-"
            }
        })
    }

    /// Nombres de los proyectos de Argos indexados por su carpeta de Claude Code.
    static func names(for projects: [Project]) -> [String: String] {
        Dictionary(projects.map { (key(forPath: $0.path), $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Sin proyecto en Argos: la carpeta sin el prefijo `-Users-<usuario>-` / `-home-<usuario>-`.
    static func fallbackName(_ key: String) -> String {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count > 3, parts[0].isEmpty, ["Users", "home"].contains(String(parts[1])) {
            let rest = parts.dropFirst(3).joined(separator: "-")
            return rest.isEmpty ? key : rest
        }
        if parts.count > 2, parts[0].isEmpty, parts[1] == "root" {
            return parts.dropFirst(2).joined(separator: "-")
        }
        return key
    }
}
