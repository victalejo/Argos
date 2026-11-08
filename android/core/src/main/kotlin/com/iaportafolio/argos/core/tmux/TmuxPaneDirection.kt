package com.iaportafolio.argos.core.tmux

/**
 * Dirección para navegar entre paneles de tmux (port de `TmuxPaneDirection` en
 * `ArgosCore/SSHServicing.swift`). [selectPaneFlag] es el flag de `tmux select-pane`.
 */
enum class TmuxPaneDirection(val selectPaneFlag: String) {
    UP("-U"),
    DOWN("-D"),
    LEFT("-L"),
    RIGHT("-R"),
}
