//
//  SSHServicing.swift
//  Argos
//
//  Abstracción del servicio SSH para inyección de dependencias. Permite que el
//  ViewModel y el controlador del terminal reciban `any SSHServicing` y que las
//  pruebas inyecten un doble sin necesidad de un servidor SSH real.
//

import Foundation

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

    func createSession(named name: String) async throws
    func renameSession(from oldName: String, to newName: String) async throws
    func killSession(named name: String) async throws

    func attachTerminal(
        session name: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws
}

extension SSHService: SSHServicing {}
