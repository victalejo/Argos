//
//  PTYSizeTests.swift
//  ArgosTests
//
//  Tamaños de PTY: zsh 5.9 corrompe su heap en `zrefresh()` con terminales
//  diminutos (core real: 2 columnas x 1 fila -> "malloc(): invalid size").
//  Estos tests fijan que esos tamaños transitorios nunca lleguen al servidor.
//

import Testing
@testable import Argos

@Suite("Tamaño de PTY (anti-crash de zsh)")
struct PTYSizeTests {

    @Test(
        "Tamaños diminutos o inválidos no se propagan como window-change",
        arguments: [(2, 1), (0, 0), (-1, 10), (80, 1), (5, 40), (PTYSize.minCols - 1, 24), (80, PTYSize.minRows - 1)]
    )
    func rejectsTinySizes(cols: Int, rows: Int) {
        #expect(!PTYSize.isUsable(cols: cols, rows: rows))
    }

    @Test(
        "Tamaños razonables sí se propagan",
        arguments: [(PTYSize.minCols, PTYSize.minRows), (80, 24), (250, 70)]
    )
    func acceptsReasonableSizes(cols: Int, rows: Int) {
        #expect(PTYSize.isUsable(cols: cols, rows: rows))
    }

    @Test("El tamaño inicial diminuto cae al valor por defecto 80x24")
    func initialFallsBack() {
        let size = PTYSize.initial(cols: 2, rows: 1)
        #expect(size.cols == PTYSize.fallbackCols)
        #expect(size.rows == PTYSize.fallbackRows)
    }

    @Test("El tamaño inicial razonable se respeta")
    func initialKeepsUsable() {
        let size = PTYSize.initial(cols: 132, rows: 40)
        #expect(size.cols == 132)
        #expect(size.rows == 40)
    }
}
