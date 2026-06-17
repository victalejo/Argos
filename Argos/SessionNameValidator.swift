//
//  SessionNameValidator.swift
//  Argos
//
//  Fase 3: validación de nombres de sesión tmux.
//
//  tmux usa ':' y '.' como separadores de target (sesión:ventana.panel), así que los
//  PROHÍBE dentro del nombre de una sesión. El '/' SÍ se permite y lo usamos por
//  convención para agrupar (ver `SessionGrouping`).
//

import Foundation

/// Valida (y normaliza) nombres de sesión tmux. Tipo puro, sin dependencias de red ni UI.
enum SessionNameValidator {

    /// Motivos por los que un nombre puede ser inválido.
    enum ValidationError: LocalizedError, Equatable {
        case empty
        case forbiddenCharacter(Character)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "El nombre no puede estar vacío."
            case .forbiddenCharacter(let character):
                return "El nombre no puede contener '\(character)': "
                     + "tmux usa ':' y '.' como separadores de sesión."
            }
        }
    }

    /// Caracteres que tmux NO admite en un nombre de sesión.
    /// (El '/' no está aquí a propósito: se permite y se usa para agrupar.)
    static let forbiddenCharacters: [Character] = [":", "."]

    /// Valida y normaliza un nombre (recorta espacios alrededor). Lanza si es inválido.
    /// Devuelve el nombre ya recortado, listo para enviar a tmux.
    static func validate(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        if let offending = forbiddenCharacters.first(where: { trimmed.contains($0) }) {
            throw ValidationError.forbiddenCharacter(offending)
        }
        return trimmed
    }

    /// ¿Es válido el nombre? Útil para habilitar/deshabilitar el botón de envío.
    static func isValid(_ rawName: String) -> Bool {
        (try? validate(rawName)) != nil
    }

    /// Mensaje para feedback en vivo en el formulario, o `nil` si el nombre es válido.
    ///
    /// No reporta el caso "vacío" para no mostrar un error antes de que el usuario
    /// teclee nada; el botón de envío se deshabilita igualmente mientras esté vacío.
    static func liveValidationMessage(for rawName: String) -> String? {
        do {
            _ = try validate(rawName)
            return nil
        } catch ValidationError.empty {
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
        }
    }
}
