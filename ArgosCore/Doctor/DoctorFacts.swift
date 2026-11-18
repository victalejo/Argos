//
//  DoctorFacts.swift
//  ArgosCore
//
//  Parser (lógica pura) de la salida del script del Doctor: líneas `clave=valor`. Es
//  tolerante: ignora cualquier línea que no tenga ese formato (MOTD, avisos del perfil de
//  login), toma el PRIMER valor de cada clave y recorta lo raro.
//

import Foundation

struct DoctorFacts: Equatable, Sendable {
    private let values: [String: String]

    init(values: [String: String]) { self.values = values }

    /// `true` si el script llegó al final (sin cortes por el camino).
    var isComplete: Bool { values["done"] == "1" }

    /// Valor sin espacios sobrantes; `nil` si falta o está vacío.
    subscript(key: String) -> String? {
        guard let raw = values[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `yes`/`no` → Bool; cualquier otra cosa o ausencia → `nil`.
    func flag(_ key: String) -> Bool? {
        switch self[key] {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    /// Enteros separados por espacios («total libre»). `nil` si alguno no es un número ≥ 0.
    func numbers(_ key: String, count: Int) -> [Int]? {
        guard let text = self[key] else { return nil }
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == count else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers
    }

    static func parse(_ output: String) -> DoctorFacts {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            guard isValidKey(key), values[key] == nil else { continue }
            values[key] = String(line[line.index(after: equals)...])
        }
        return DoctorFacts(values: values)
    }

    /// Claves del script: `[a-z0-9._]+` (descarta ruido como `export FOO=bar`).
    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95
        }
    }
}
