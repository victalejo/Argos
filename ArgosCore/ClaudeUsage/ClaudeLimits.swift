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

    /// Margen para considerar «el mismo reinicio» entre lecturas.
    static let sameResetTolerance: TimeInterval = 300

    /// Misma clase y mismo reinicio (con margen): es la misma ventana, solo puede subir.
    func isSameWindow(as other: ClaudeLimitWindow) -> Bool {
        guard kind == other.kind else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < Self.sameResetTolerance
        default: return false
        }
    }

    /// Nivel de aviso de un porcentaje.
    static func level(percent: Int) -> ClaudeLimitsLevel {
        percent >= ClaudeLimitsStatus.criticalFrom ? .critical : percent >= ClaudeLimitsStatus.highFrom ? .high : .normal
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
    /// el archivo (`<epoch>` + JSON). La hora de guardado es del reloj del servidor y se pasa
    /// al local con la diferencia entre `now` y `localNow`; `resets_at` es hora de Anthropic
    /// y no se corrige. `nil` si no hay archivo o no trae límites.
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
        guard let windows = Self.windows(fromStatusLineJSON: json), !windows.isEmpty else { return nil }
        self.init(windows: windows, capturedAt: Date(timeIntervalSince1970: captured + offset))
    }

    init(windows: [ClaudeLimitWindow], capturedAt: Date) {
        self.windows = windows.sorted { $0.sortKey < $1.sortKey }
        self.capturedAt = capturedAt
    }

    /// Ventanas de `rate_limits` del JSON de la statusline. `nil` si el JSON no es válido o
    /// no trae `rate_limits`.
    static func windows(fromStatusLineJSON json: String) -> [ClaudeLimitWindow]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any]
        else { return nil }
        return limits.compactMap { kind, value -> ClaudeLimitWindow? in
            guard let row = value as? [String: Any],
                  let used = (row["used_percentage"] as? NSNumber)?.doubleValue
            else { return nil }
            return ClaudeLimitWindow(kind: kind, usedPercent: used, resetsAt: resetDate(row["resets_at"]))
        }
    }

    /// Con la lectura anterior: dentro de una MISMA ventana (mismo reinicio) el uso no baja.
    /// Varias sesiones de Claude escriben el archivo y una parada puede dejar un porcentaje
    /// viejo; se conserva el más alto visto para esa ventana.
    func merging(previous: ClaudeLimitsReading?) -> ClaudeLimitsReading {
        guard let previous else { return self }
        let merged = windows.map { window -> ClaudeLimitWindow in
            guard let old = previous.windows.first(where: { $0.isSameWindow(as: window) }),
                  old.usedPercent > window.usedPercent
            else { return window }
            return ClaudeLimitWindow(kind: window.kind, usedPercent: old.usedPercent, resetsAt: window.resetsAt)
        }
        return ClaudeLimitsReading(windows: merged, capturedAt: max(capturedAt, previous.capturedAt))
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
        return ClaudeLimitsStatus(reading: reading, worst: worst, worstPercent: percent, level: ClaudeLimitWindow.level(percent: percent))
    }

    var title: String { Self.title(for: level) }

    static func title(for level: ClaudeLimitsLevel) -> String {
        switch level {
        case .normal: return String(localized: "Uso de Claude")
        case .high: return String(localized: "Te acercas al límite de Claude")
        case .critical: return String(localized: "Claude está casi en el límite")
        }
    }

    /// «Llevas el 87 % de la ventana de 5 h; se reinicia a las 18:30».
    func message(now: Date = Date()) -> String {
        Self.message(window: worst, percent: worstPercent, now: now)
    }

    static func message(window: ClaudeLimitWindow, percent: Int, now: Date = Date()) -> String {
        let label = window.label
        if let reset = window.resetsAt, reset > now {
            let when = resetText(reset, now: now)
            return String(localized: "Llevas el \(percent) % de «\(label)»; se reinicia \(when).")
        }
        return String(localized: "Llevas el \(percent) % de «\(label)».")
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

/// Paso de una ventana a «alto» o «crítico». Se decide ventana a ventana: que cambie cuál
/// es la más llena no vuelve a avisar de una que ya avisó.
struct ClaudeLimitAlert: Equatable, Sendable {
    let window: ClaudeLimitWindow
    let percent: Int
    let level: ClaudeLimitsLevel

    var title: String { ClaudeLimitsStatus.title(for: level) }

    func message(now: Date = Date()) -> String {
        ClaudeLimitsStatus.message(window: window, percent: percent, now: now)
    }

    /// Identificador estable: misma ventana, mismo reinicio y mismo nivel = mismo aviso
    /// (sirve para no repetirlo entre arranques de la app).
    var key: String {
        let tolerance = ClaudeLimitWindow.sameResetTolerance
        let reset = window.resetsAt.map { String(Int(($0.timeIntervalSince1970 / tolerance).rounded())) } ?? "-"
        return "\(window.kind)-\(reset)-\(level.rawValue)"
    }

    /// Avisos nuevos al pasar de `previous` a `current`: ventanas que SUBEN a alto o crítico
    /// (o que aparecen ya altas). La más grave primero.
    static func transitions(from previous: ClaudeLimitsReading?, to current: ClaudeLimitsReading?, now: Date = Date()) -> [ClaudeLimitAlert] {
        guard let current else { return [] }
        let alerts = current.windows.compactMap { window -> ClaudeLimitAlert? in
            let percent = Int(window.effectivePercent(now: now).rounded())
            let level = ClaudeLimitWindow.level(percent: percent)
            guard level > .normal else { return nil }
            if let old = previous?.windows.first(where: { $0.isSameWindow(as: window) }),
               ClaudeLimitWindow.level(percent: Int(old.effectivePercent(now: now).rounded())) >= level {
                return nil
            }
            return ClaudeLimitAlert(window: window, percent: percent, level: level)
        }
        return alerts.sorted { $0.percent > $1.percent }
    }
}
