//
//  TmuxWindow.swift
//  Argos
//
//  Modelo de una ventana de tmux. Parsea una línea con el formato EXACTO emitido por:
//      tmux list-windows -t <sesión> -F '#{window_index}|#{window_name}|#{window_active}|#{window_panes}'
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

    var id: Int { index }

    init(index: Int, name: String, isActive: Bool, paneCount: Int) {
        self.index = index
        self.name = name
        self.isActive = isActive
        self.paneCount = paneCount
    }

    /// Parsea una línea de `tmux list-windows -F`. Formato (4 campos por `|`):
    /// `índice|nombre|activa(1/0)|paneles`. Devuelve `nil` si no cumple.
    init?(line: String) {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4 else { return nil }

        guard
            let index = Int(fields[0]),
            !fields[1].isEmpty,
            let activeFlag = Int(fields[2]),
            let paneCount = Int(fields[3])
        else {
            return nil
        }

        self.index = index
        self.name = fields[1]
        self.isActive = activeFlag != 0
        self.paneCount = paneCount
    }
}
