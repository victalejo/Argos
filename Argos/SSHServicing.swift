//
//  SSHServicing.swift
//  Argos
//
//  Abstracción del servicio SSH para inyección de dependencias. Permite que el
//  ViewModel y el controlador del terminal reciban `any SSHServicing` y que las
//  pruebas inyecten un doble sin necesidad de un servidor SSH real.
//

import Foundation

/// Dirección para navegar entre paneles de tmux (mapea a `select-pane -U/-D/-L/-R`).
enum TmuxPaneDirection: String, Sendable, CaseIterable {
    case up, down, left, right

    /// Flag de `tmux select-pane` correspondiente.
    var selectPaneFlag: String {
        switch self {
        case .up: return "-U"
        case .down: return "-D"
        case .left: return "-L"
        case .right: return "-R"
        }
    }
}

/// Operaciones de un servicio SSH/tmux. `SSHService` (el actor real) la cumple;
/// los tests pueden proveer un mock.
protocol SSHServicing: Sendable {
    func listSessions() async throws -> [TmuxSession]
    func disconnect() async

    func isTmuxInstalled() async throws -> Bool
    func canUseSudoNonInteractive() async throws -> Bool
    func installTmuxWithApt() async throws
    func tmuxConfigExists() async throws -> Bool
    func writeDefaultTmuxConfig() async throws
    func enableClipboardForwarding() async

    func createSession(named name: String) async throws
    func renameSession(from oldName: String, to newName: String) async throws
    func killSession(named name: String) async throws

    func listWindows(session: String) async throws -> [TmuxWindow]
    func selectWindow(session: String, index: Int) async throws
    func newWindow(session: String) async throws

    func splitPane(session: String, vertical: Bool) async throws
    func selectPane(session: String, direction: TmuxPaneDirection) async throws
    func zoomPane(session: String) async throws
    func killPane(session: String) async throws

    func uploadPastedFile(data: Data, fileExtension: String) async throws -> String
    func uploadDroppedFile(data: Data, originalName: String) async throws -> String

    func attachTerminal(
        session name: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws
}

extension SSHService: SSHServicing {}
