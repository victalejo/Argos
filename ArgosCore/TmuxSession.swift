//
//  TmuxSession.swift
//  Argos
//
//  Modelo de una sesión tmux. Parsea una línea con el formato EXACTO emitido por:
//      tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_created}'
//

import Foundation

/// Una sesión tmux en el servidor remoto.
struct TmuxSession: Identifiable, Hashable, Sendable {
    /// `#{session_name}` — nombre de la sesión (único por servidor tmux).
    let name: String
    /// `#{session_windows}` — número de ventanas abiertas en la sesión.
    let windowCount: Int
    /// `#{session_attached}` — `1` si hay algún cliente conectado, `0` si no.
    let isAttached: Bool
    /// `#{session_created}` — instante de creación (epoch en segundos).
    let createdAt: Date

    /// El nombre identifica la sesión de forma única dentro de un servidor tmux.
    var id: String { name }

    /// Inicializador directo (usado en previews/tests).
    init(name: String, windowCount: Int, isAttached: Bool, createdAt: Date) {
        self.name = name
        self.windowCount = windowCount
        self.isAttached = isAttached
        self.createdAt = createdAt
    }

    /// Parsea una única línea de la salida de `tmux list-sessions -F`.
    ///
    /// Formato esperado (4 campos separados por `|`):
    /// `nombre|ventanas|attached(1/0)|created(epoch)`
    ///
    /// Devuelve `nil` si la línea está vacía o no cumple el formato, para poder
    /// descartar líneas inesperadas sin abortar el parseo del resto.
    init?(line: String) {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // Los tres últimos campos son numéricos; el nombre es todo lo anterior, porque
        // tmux admite '|' en un nombre de sesión (creada fuera de Argos).
        let fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else { return nil }

        let name = fields.dropLast(3).joined(separator: "|")
        let numeric = Array(fields.suffix(3))
        guard
            !name.isEmpty,
            let windowCount = Int(numeric[0]),
            let attachedFlag = Int(numeric[1]),
            let epoch = TimeInterval(numeric[2])
        else {
            return nil
        }

        self.name = name
        self.windowCount = windowCount
        self.isAttached = attachedFlag != 0
        self.createdAt = Date(timeIntervalSince1970: epoch)
    }
}
