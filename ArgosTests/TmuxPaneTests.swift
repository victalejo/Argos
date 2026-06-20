//
//  TmuxPaneTests.swift
//  ArgosTests
//
//  Fija el mapeo dirección → flag de `tmux select-pane` (un flag equivocado movería el
//  foco en la dirección contraria).
//

import Testing
@testable import Argos

@Suite("Paneles de tmux")
struct TmuxPaneTests {

    @Test("selectPaneFlag mapea cada dirección a su flag de tmux", arguments: [
        (TmuxPaneDirection.up, "-U"),
        (TmuxPaneDirection.down, "-D"),
        (TmuxPaneDirection.left, "-L"),
        (TmuxPaneDirection.right, "-R"),
    ])
    func selectPaneFlag(direction: TmuxPaneDirection, expected: String) {
        #expect(direction.selectPaneFlag == expected)
    }

    @Test("Hay exactamente cuatro direcciones")
    func allCases() {
        #expect(TmuxPaneDirection.allCases.count == 4)
    }
}
