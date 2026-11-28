//
//  SessionContextPreview.swift
//  ArgosCore
//
//  «Ver lo que verá Claude» (lógica pura): la salida del script de contexto tal como la
//  recibiría Claude, saneada otra vez para enseñarla (el servidor no es de fiar).
//

import Foundation

struct SessionContextPreview: Equatable, Sendable {
    /// Texto que recibiría Claude (vacío: no recibiría nada).
    let text: String

    var isEmpty: Bool { text.isEmpty }

    /// Tope al mostrar: algo más que el del script, por si el servidor manda de más.
    static let maxDisplayCharacters = 4000

    init(output: String) {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.sanitizedLine(String($0)) }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(joined.prefix(Self.maxDisplayCharacters))
    }

    /// Sin caracteres de control ni de formato (incluidos los bidi), salvo el tabulador.
    static func sanitizedLine(_ line: String) -> String {
        let scalars = line.unicodeScalars.filter { scalar in
            if scalar == "\t" { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
