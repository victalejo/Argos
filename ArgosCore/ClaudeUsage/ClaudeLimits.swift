//
//  ClaudeLimits.swift
//  ArgosCore
//
//  Límites de uso de la suscripción de Claude (ventana de 5 h, semanal…) tal como los ve
//  Claude Code (lógica pura). Claude Code pasa a su statusline un JSON con
//  `rate_limits: {five_hour: {used_percentage, resets_at}, seven_day: {…}}`; el script de
//  statusline de Argos (`ClaudeLimitsInstaller`) lo guarda en el servidor y la sección
//  `limits` del sondeo (`WorkspacePollCommand`) lo lee. Android lo porta en
//  `ClaudeLimits.kt`.
//
//  Formato del archivo (`~/.config/argos/claude-limits.json`): primera línea, la hora del
//  servidor (epoch) en que se guardó; el resto, el JSON de la statusline tal cual.
//

import Foundation

/// Una ventana de límite («5 h», «semana»…).
struct ClaudeLimitWindow: Equatable, Sendable {
    /// Clave del servidor de Anthropic (`five_hour`, `seven_day`, `seven_day_opus`…).
    let kind: String
    /// Porcentaje usado (0…100) cuando se leyó.
    let usedPercent: Double
    /// Cuándo se reinicia, en el reloj de ESTE dispositivo (`nil` si no lo dice).
    let resetsAt: Date?

    static let fiveHour = "five_hour"
    static let sevenDay = "seven_day"

    /// Porcentaje que vale ahora: una ventana ya reiniciada vuelve a 0.
    func effectivePercent(now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(100, max(0, usedPercent))
    }

    /// Nombre para mostrar.
    var label: String {
        switch kind {
        case Self.fiveHour: return String(localized: "Ventana de 5 h")
        case Self.sevenDay: return String(localized: "Semana")
        default:
            if kind.hasPrefix(Self.sevenDay + "_") {
                let scope = kind.dropFirst(Self.sevenDay.count + 1).replacingOccurrences(of: "_", with: " ").capitalized
                return String(localized: "Semana (\(scope))")
            }
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Orden: 5 h, semana y luego el resto por nombre.
    fileprivate var sortKey: (Int, String) {
        switch kind {
        case Self.fiveHour: return (0, kind)
        case Self.sevenDay: return (1, kind)
        default: return (2, kind)
        }
    }
}

/// Lectura de límites de un servidor.
struct ClaudeLimitsReading: Equatable, Sendable {
    let windows: [ClaudeLimitWindow]
    /// Cuándo los guardó la statusline, en el reloj de este dispositivo.
    let capturedAt: Date

    /// Interpreta la sección `limits` del sondeo: `now <epoch del servidor>` y, si existe,
    /// el archivo (`<epoch>` + JSON). Las horas del servidor se pasan al reloj local con
    /// la diferencia entre `now` y `localNow`. `nil` si no hay archivo o no trae límites.
    init?(lines: [String], localNow: Date = Date()) {
        guard let nowLine = lines.first(where: { $0.hasPrefix("now ") }),
              let serverNow = Double(nowLine.dropFirst(4).trimmingCharacters(in: .whitespaces))
        else { return nil }
        let rest = lines.drop { !$0.hasPrefix("now ") }.dropFirst()
        guard let stampLine = rest.first,
              let captured = Double(stampLine.trimmingCharacters(in: .whitespaces))
        else { return nil }
        let json = rest.dropFirst().joined(separator: "\n")
        let offset = localNow.timeIntervalSince1970 - serverNow
        guard let windows = Self.windows(fromStatusLineJSON: json, clockOffset: offset), !windows.isEmpty else { return nil }
        self.init(windows: windows, capturedAt: Date(timeIntervalSince1970: captured + offset))
    }

    init(windows: [ClaudeLimitWindow], capturedAt: Date) {
        self.windows = windows.sorted { $0.sortKey < $1.sortKey }
        self.capturedAt = capturedAt
    }

    /// Ventanas de `rate_limits` del JSON de la statusline. `clockOffset` se suma a las
    /// horas del servidor. `nil` si el JSON no es válido o no trae `rate_limits`.
    static func windows(fromStatusLineJSON json: String, clockOffset: TimeInterval = 0) -> [ClaudeLimitWindow]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return nil }
        return limits.compactMap { kind, value -> ClaudeLimitWindow? in
            guard let row = value as? [String: Any],
                  let used = (row["used_percentage"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = resetDate(row["resets_at"]).map { $0.addingTimeInterval(clockOffset) }
            return ClaudeLimitWindow(kind: kind, usedPercent: used, resetsAt: resets)
        }
    }

    /// `resets_at` llega en segundos epoch; por si acaso, también ISO 8601.
    private static func resetDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            // Milisegundos por error: más allá del año 5000 en segundos.
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        if let text = value as? String {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}

enum ClaudeLimitsLevel: Int, Comparable, Sendable {
    case normal
    case high
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Estado de los límites de un servidor tal como lo enseña la app.
struct ClaudeLimitsStatus: Equatable, Sendable {
    let reading: ClaudeLimitsReading
    /// La ventana más llena (la que manda en el aviso).
    let worst: ClaudeLimitWindow
    let worstPercent: Int
    let level: ClaudeLimitsLevel

    /// Desde aquí se avisa («vas al 85 %»).
    static let highFrom = 85
    /// Desde aquí, el aviso es urgente.
    static let criticalFrom = 95

    static func evaluate(_ reading: ClaudeLimitsReading, now: Date = Date()) -> ClaudeLimitsStatus? {
        let ranked = reading.windows.map { ($0, Int($0.effectivePercent(now: now).rounded())) }
        guard let (worst, percent) = ranked.max(by: { $0.1 < $1.1 }) else { return nil }
        let level: ClaudeLimitsLevel = percent >= criticalFrom ? .critical : percent >= highFrom ? .high : .normal
        return ClaudeLimitsStatus(reading: reading, worst: worst, worstPercent: percent, level: level)
    }

    var title: String {
        switch level {
        case .normal: return String(localized: "Uso de Claude")
        case .high: return String(localized: "Te acercas al límite de Claude")
        case .critical: return String(localized: "Claude está casi en el límite")
        }
    }

    /// «Llevas el 87 % de la ventana de 5 h; se reinicia a las 18:30».
    func message(now: Date = Date()) -> String {
        let window = worst.label
        if let reset = worst.resetsAt, reset > now {
            let when = Self.resetText(reset, now: now)
            return String(localized: "Llevas el \(worstPercent) % de «\(window)»; se reinicia \(when).")
        }
        return String(localized: "Llevas el \(worstPercent) % de «\(window)».")
    }

    /// «a las 18:30» hoy, «mañana a las 9:00» o «el lun 9:00» más adelante.
    static func resetText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "a las \(time)")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "mañana a las \(time)")
        }
        let day = date.formatted(.dateTime.weekday(.abbreviated).day())
        return String(localized: "el \(day) a las \(time)")
    }
}

/// Paso de una ventana a «alto» o «crítico» (para avisar una sola vez por ventana y nivel).
struct ClaudeLimitAlert: Equatable, Sendable {
    let status: ClaudeLimitsStatus

    /// Margen para considerar «el mismo reinicio»: la hora pasa del reloj del servidor al
    /// local con una diferencia que baila unos segundos entre vueltas.
    static let sameResetTolerance: TimeInterval = 300

    /// Identificador estable: misma ventana, mismo reinicio y mismo nivel = mismo aviso.
    var key: String {
        let reset = status.worst.resetsAt.map { String(Int(($0.timeIntervalSince1970 / Self.sameResetTolerance).rounded())) } ?? "-"
        return "\(status.worst.kind)-\(reset)-\(status.level.rawValue)"
    }

    /// Aviso nuevo al pasar de `previous` a `current` (solo al SUBIR de nivel, o con una
    /// ventana nueva ya alta).
    static func transition(from previous: ClaudeLimitsStatus?, to current: ClaudeLimitsStatus?) -> ClaudeLimitAlert? {
        guard let current, current.level > .normal else { return nil }
        if let previous, previous.level >= current.level, previous.worst.kind == current.worst.kind,
           sameReset(previous.worst.resetsAt, current.worst.resetsAt) {
            return nil
        }
        return ClaudeLimitAlert(status: current)
    }

    private static func sameReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < sameResetTolerance
        default: return false
        }
    }
}
