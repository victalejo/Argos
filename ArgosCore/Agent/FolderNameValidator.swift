//
//  FolderNameValidator.swift
//  Argos
//
//  Valida el nombre de una carpeta nueva del servidor (una sola carpeta, sin rutas).
//

import Foundation

enum FolderNameValidator {
    enum Failure: LocalizedError, Equatable {
        case empty
        case reserved
        case containsSlash
        case controlCharacter
        case tooLong

        var errorDescription: String? {
            switch self {
            case .empty: return "Escribe un nombre para la carpeta."
            case .reserved: return "«.» y «..» no son nombres válidos."
            case .containsSlash: return "El nombre no puede llevar «/». Crea una carpeta cada vez."
            case .controlCharacter: return "El nombre tiene caracteres no válidos."
            case .tooLong: return "El nombre es demasiado largo (máximo 255 bytes)."
            }
        }
    }

    /// Devuelve el nombre sin espacios sobrantes o el motivo por el que no vale.
    static func validate(_ raw: String) -> Result<String, Failure> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.empty) }
        if name == "." || name == ".." { return .failure(.reserved) }
        if name.contains("/") { return .failure(.containsSlash) }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .failure(.controlCharacter)
        }
        if name.utf8.count > 255 { return .failure(.tooLong) }
        return .success(name)
    }
}
