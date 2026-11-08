//
//  TerminalAttachment.swift
//  ArgosCore
//
//  Reglas puras de los adjuntos del terminal en iPhone/iPad (fotos y archivos que se
//  suben al servidor para que la app remota, p. ej. Claude Code, los lea por ruta).
//

import Foundation

enum TerminalAttachment {

    /// Tope por archivo: se lee entero en memoria antes de subirlo por SFTP.
    static let maxBytes = 100 * 1024 * 1024

    static func tooLargeMessage(fileName: String) -> String {
        "«\(fileName)» pesa más de \(maxBytes / (1024 * 1024)) MB: súbelo de otra forma."
    }

    /// Nombre para una foto de la fototeca (no trae nombre de archivo): `foto-AAAAMMDD-HHMMSS.ext`.
    static func photoFileName(fileExtension: String?, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let cleaned = (fileExtension ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return "foto-\(formatter.string(from: date)).\(cleaned.isEmpty ? "jpg" : cleaned)"
    }
}
