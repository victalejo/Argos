//
//  DiagnosticLog.swift
//  ArgosCore
//
//  Registro propio de la app para «Copiar diagnóstico»: los últimos minutos de `os.Logger`
//  del subsistema de Argos, leídos con `OSLogStore` (ámbito: este proceso). Si el almacén no
//  está disponible (sandbox, permisos), el informe se genera igual y lo dice.
//  El formato y el recorte por tamaño son lógica pura (`DiagnosticLogFormatter`).
//

import Foundation
import OSLog

/// Una línea del registro ya extraída del almacén.
struct DiagnosticLogLine: Equatable, Sendable {
    let date: Date
    let level: String
    let category: String
    let message: String
}

/// Lo que el informe sabe del registro.
enum DiagnosticLogExcerpt: Equatable, Sendable {
    case lines([String], truncated: Bool)
    case unavailable(String)
}

enum DiagnosticLogFormatter {

    static let defaultMinutes = 10
    /// Tope del texto del registro (UTF-8): un informe pegable en un issue.
    static let defaultMaxBytes = 30_000

    /// `HH:mm:ss.SSS [nivel] categoría: mensaje` (hora en UTC: el informe es comparable entre equipos).
    static func format(_ line: DiagnosticLogLine) -> String {
        let flat = line.message.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(timeFormatter.string(from: line.date)) [\(line.level)] \(line.category): \(flat)"
    }

    /// Conserva las líneas MÁS RECIENTES que quepan en `maxBytes` (en orden cronológico).
    static func excerpt(from lines: [DiagnosticLogLine], maxBytes: Int = defaultMaxBytes) -> DiagnosticLogExcerpt {
        var kept: [String] = []
        var used = 0
        var truncated = false
        for line in lines.sorted(by: { $0.date < $1.date }).reversed() {
            let text = format(line)
            let cost = text.utf8.count + 1
            if used + cost > maxBytes { truncated = true; break }
            kept.append(text)
            used += cost
        }
        return .lines(kept.reversed(), truncated: truncated)
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }
}

enum DiagnosticLogReader {

    /// Lee los últimos `minutes` minutos del registro de Argos. Nunca lanza: devuelve `.unavailable`.
    static func read(
        minutes: Int = DiagnosticLogFormatter.defaultMinutes,
        maxBytes: Int = DiagnosticLogFormatter.defaultMaxBytes,
        now: Date = Date()
    ) async -> DiagnosticLogExcerpt {
        await Task.detached(priority: .utility) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(date: now.addingTimeInterval(-Double(minutes) * 60))
                let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
                let entries = try store.getEntries(at: position, matching: predicate)
                let lines: [DiagnosticLogLine] = entries.compactMap { entry in
                    guard let log = entry as? OSLogEntryLog else { return nil }
                    return DiagnosticLogLine(
                        date: log.date, level: levelName(log.level), category: log.category, message: log.composedMessage
                    )
                }
                return DiagnosticLogFormatter.excerpt(from: lines, maxBytes: maxBytes)
            } catch {
                Log.store.notice("diagnóstico: registro no disponible: \(error.localizedDescription, privacy: .public)")
                return .unavailable(error.localizedDescription)
            }
        }.value
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "?"
        }
    }
}
