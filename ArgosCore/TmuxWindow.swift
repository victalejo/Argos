//
//  TmuxWindow.swift
//  Argos
//
//  Modelo de una ventana de tmux. Parsea una línea con el formato EXACTO emitido por:
//      tmux list-windows -t <sesión> -F '#{window_index}|#{window_active}|#{window_panes}|#{@argos_color}|#{window_name}'
//  (ver `SSHService.listWindowsFormat`). El nombre va AL FINAL para que un '|' dentro
//  del nombre no rompa el parseo.
//

import Foundation

/// Una ventana dentro de una sesión tmux.
struct TmuxWindow: Identifiable, Hashable, Sendable {
    /// `#{window_index}` — índice de la ventana (único dentro de la sesión).
    let index: Int
    /// `#{window_name}` — nombre de la ventana.
    let name: String
    /// `#{window_active}` — `1` si es la ventana activa de la sesión.
    let isActive: Bool
    /// `#{window_panes}` — número de paneles en la ventana.
    let paneCount: Int
    /// `#{@argos_color}` — color elegido por el usuario (opción de usuario de tmux), o `nil`.
    let color: WindowColor?

    var id: Int { index }

    init(index: Int, name: String, isActive: Bool, paneCount: Int, color: WindowColor? = nil) {
        self.index = index
        self.name = name
        self.isActive = isActive
        self.paneCount = paneCount
        self.color = color
    }

    /// Parsea una línea de `tmux list-windows -F`. Formato (≥5 campos por `|`):
    /// `índice|activa(1/0)|paneles|color|nombre`, donde el nombre es el resto de la línea.
    /// Devuelve `nil` si no cumple. Un color desconocido se trata como "sin color".
    init?(line: String) {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let fields = raw.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else { return nil }

        guard
            let index = Int(fields[0]),
            let activeFlag = Int(fields[1]),
            let paneCount = Int(fields[2]),
            !fields[4].isEmpty
        else {
            return nil
        }

        self.index = index
        self.isActive = activeFlag != 0
        self.paneCount = paneCount
        self.color = WindowColor(rawValue: fields[3])
        self.name = fields[4]
    }
}

/// Paleta de colores para etiquetar ventanas. El `rawValue` es lo que se guarda en la
/// opción de usuario `@argos_color` de tmux (persiste en el servidor).
enum WindowColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, mint, blue, purple, pink, gray

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .red: return "Rojo"
        case .orange: return "Naranja"
        case .yellow: return "Amarillo"
        case .green: return "Verde"
        case .mint: return "Menta"
        case .blue: return "Azul"
        case .purple: return "Morado"
        case .pink: return "Rosa"
        case .gray: return "Gris"
        }
    }
}

/// Valida nombres de ventana tmux. Más permisivo que `SessionNameValidator`: las
/// ventanas se apuntan por índice, así que ':' y '.' sí se admiten.
enum WindowNameValidator {

    enum ValidationError: LocalizedError, Equatable {
        case empty
        case controlCharacter
        case leadingDash

        var errorDescription: String? {
            switch self {
            case .empty:
                return "El nombre no puede estar vacío."
            case .controlCharacter:
                return "El nombre no puede contener saltos de línea, tabuladores "
                     + "ni otros caracteres de control."
            case .leadingDash:
                return "El nombre no puede empezar por '-' "
                     + "(tmux lo interpretaría como una opción)."
            }
        }
    }

    /// Valida y normaliza (recorta espacios). Lanza si es inválido.
    static func validate(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw ValidationError.controlCharacter
        }
        if trimmed.hasPrefix("-") { throw ValidationError.leadingDash }
        return trimmed
    }

    static func isValid(_ rawName: String) -> Bool {
        (try? validate(rawName)) != nil
    }

    /// Mensaje para feedback en vivo, o `nil` si es válido (o aún está vacío).
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
