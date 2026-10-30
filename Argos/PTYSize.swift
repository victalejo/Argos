//
//  PTYSize.swift
//  Argos
//
//  Saneado del tamaño del PTY remoto. Mientras SwiftUI maqueta la vista, SwiftTerm
//  puede reportar tamaños transitorios absurdos (p. ej. 2x1). Propagarlos como
//  window-change hace que zsh 5.9 corrompa su heap en `zrefresh()` y aborte con
//  "malloc(): invalid size (unsorted)", matando el shell antes de `exec tmux`.
//

import Foundation

/// Reglas puras para decidir qué tamaño de terminal se envía al servidor.
enum PTYSize {
    /// Por debajo de esto el tamaño se considera transitorio (layout en curso).
    static let minCols = 20
    static let minRows = 5

    /// Tamaño del PTY cuando el terminal aún no tiene un tamaño utilizable.
    static let fallbackCols = 80
    static let fallbackRows = 24

    /// `true` si el tamaño es seguro para enviarlo como window-change.
    static func isUsable(cols: Int, rows: Int) -> Bool {
        cols >= minCols && rows >= minRows
    }

    /// Tamaño con el que abrir el PTY: el del terminal si es utilizable, o 80x24.
    static func initial(cols: Int, rows: Int) -> (cols: Int, rows: Int) {
        isUsable(cols: cols, rows: rows) ? (cols, rows) : (fallbackCols, fallbackRows)
    }
}
