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

/// Lo que el informe sabe del registro (sin recortar: el tope se aplica DESPUÉS de redactar).
enum DiagnosticLogExcerpt: Equatable, Sendable {
    case entries([DiagnosticLogLine])
    case unavailable(String)
}

/// Qué parte del registro entra en el informe y con qué topes.
struct DiagnosticLogPolicy: Equatable, Sendable {
    /// Incluye las entradas `debug` y la categoría `agent` (stderr crudo de `claude` y otros
    /// textos que vienen del servidor). Por defecto NO: pueden llevar datos sin control.
    var includesTechnicalDetail = false
    var maxBytes = DiagnosticLogFormatter.defaultMaxBytes
    var maxLineCharacters = DiagnosticLogFormatter.defaultMaxLineCharacters

    /// Categorías cuyo texto puede venir del servidor sin control.
    static let remoteTextCategories: Set<String> = ["agent"]

    func admits(_ line: DiagnosticLogLine) -> Bool {
        includesTechnicalDetail || (line.level != "debug" && !Self.remoteTextCategories.contains(line.category))
    }
}

enum DiagnosticLogFormatter {

    static let defaultMinutes = 10
    /// Tope del texto del registro (UTF-8): un informe pegable en un issue.
    static let defaultMaxBytes = 30_000
    /// Una línea de registro con un volcado enorme de un comando no debe ocupar el informe.
    static let defaultMaxLineCharacters = 600

    /// `HH:mm:ss.SSS [nivel] categoría: mensaje` (hora en UTC: el informe es comparable entre equipos).
    static func format(_ line: DiagnosticLogLine) -> String {
        let flat = line.message.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(timeFormatter.string(from: line.date)) [\(line.level)] \(line.category): \(flat)"
    }

    /// Recorta una línea YA redactada (cortar antes podría dejar media clave a la vista).
    static func clip(_ line: String, to limit: Int) -> String {
        line.count <= limit ? line : String(line.prefix(limit)) + "… [recortado]"
    }

    /// Conserva las líneas MÁS RECIENTES que quepan en `maxBytes` (en el orden recibido).
    static func newest(of lines: [String], maxBytes: Int) -> (lines: [String], truncated: Bool) {
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            let cost = line.utf8.count + 1
            if used + cost > maxBytes { return (kept.reversed(), true) }
            kept.append(line)
            used += cost
        }
        return (kept.reversed(), false)
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

    /// Entradas más recientes que se leen del almacén antes de filtrar y redactar.
    static let rawEntryLimit = 3_000

    /// Lee los últimos `minutes` minutos del registro de Argos. Nunca lanza: devuelve `.unavailable`.
    static func read(
        minutes: Int = DiagnosticLogFormatter.defaultMinutes,
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
                // Tope de seguridad de lo que se lee; el recorte del informe va después de redactar.
                return .entries(Array(lines.sorted { $0.date < $1.date }.suffix(rawEntryLimit)))
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
