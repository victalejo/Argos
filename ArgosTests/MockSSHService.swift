//
//  MockSSHService.swift
//  ArgosTests
//
//  Doble de prueba de `SSHServicing`: permite ejercitar `SessionsViewModel` y el flujo
//  de bootstrap (verificar → instalar → configurar → listar) sin un servidor SSH real.
//
//  `@unchecked Sendable`: el estado mutable es de configuración fijada por la prueba antes
//  de usarse y consultada de forma secuencial; no hay concurrencia real en los tests.
//

import Foundation
@testable import Argos

final class MockSSHService: SSHServicing, @unchecked Sendable {

    // MARK: - Comportamiento configurable
    var tmuxInstalled = true
    var hasSudo = true
    var configExists = true
    var sessions: [TmuxSession] = []
    /// Si no es `nil`, `listSessions()` lanza este error (simula fallo de conexión).
    var listError: Error?
    /// Si no es `nil`, `killSession(named:)` lanza este error.
    var killError: Error?
    /// Si no es `nil`, `createSession(named:)` lanza este error.
    var createError: Error?

    // MARK: - Registro de llamadas (para aserciones)
    private(set) var installCalled = false
    private(set) var writeConfigCalled = false
    private(set) var clipboardForwardingCalled = false
    private(set) var createdNames: [String] = []
    private(set) var renamedTo: [String] = []
    private(set) var killedNames: [String] = []

    // MARK: - Bootstrap de tmux
    func isTmuxInstalled() async throws -> Bool { tmuxInstalled }
    func canUseSudoNonInteractive() async throws -> Bool { hasSudo }
    func installTmuxWithApt() async throws { installCalled = true; tmuxInstalled = true }
    func tmuxConfigExists() async throws -> Bool { configExists }
    func writeDefaultTmuxConfig() async throws { writeConfigCalled = true; configExists = true }
    func enableClipboardForwarding() async { clipboardForwardingCalled = true }

    // MARK: - Listado / CRUD de sesiones
    func listSessions() async throws -> [TmuxSession] {
        if let listError { throw listError }
        return sessions
    }

    func createSession(named name: String) async throws {
        if let createError { throw createError }
        createdNames.append(name)
        sessions.append(TmuxSession(name: name, windowCount: 1, isAttached: false,
                                    createdAt: Date(timeIntervalSince1970: 0)))
    }

    func renameSession(from oldName: String, to newName: String) async throws {
        renamedTo.append(newName)
        if let index = sessions.firstIndex(where: { $0.name == oldName }) {
            let old = sessions[index]
            sessions[index] = TmuxSession(name: newName, windowCount: old.windowCount,
                                          isAttached: old.isAttached, createdAt: old.createdAt)
        }
    }

    func killSession(named name: String) async throws {
        if let killError { throw killError }
        killedNames.append(name)
        sessions.removeAll { $0.name == name }
    }

    // MARK: - Ventanas
    func listWindows(session: String) async throws -> [TmuxWindow] { [] }
    func selectWindow(session: String, index: Int) async throws {}
    func newWindow(session: String) async throws {}

    // MARK: - Paneles
    private(set) var splitVerticalCalls: [Bool] = []
    private(set) var selectedPaneDirections: [TmuxPaneDirection] = []
    private(set) var zoomPaneCalls = 0
    private(set) var killPaneCalls = 0

    func splitPane(session: String, vertical: Bool) async throws { splitVerticalCalls.append(vertical) }
    func selectPane(session: String, direction: TmuxPaneDirection) async throws {
        selectedPaneDirections.append(direction)
    }
    func zoomPane(session: String) async throws { zoomPaneCalls += 1 }
    func killPane(session: String) async throws { killPaneCalls += 1 }

    // MARK: - send-keys
    /// Registro de envíos: (sesión, texto, enter).
    private(set) var sentKeys: [(session: String, keys: String, enter: Bool)] = []
    func sendKeys(session: String, keys: String, enter: Bool) async throws {
        sentKeys.append((session, keys, enter))
    }

    // MARK: - Transferencia de archivos
    func uploadPastedFile(data: Data, fileExtension: String) async throws -> String { "" }
    func uploadDroppedFile(data: Data, originalName: String) async throws -> String { "" }

    // MARK: - Ciclo de vida / terminal
    func disconnect() async {}

    func attachTerminal(
        session name: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws {
        output.finish()
    }

    // MARK: - Panel de agente

    /// Ruta que devuelve `locateClaude` (nil simula "no instalado").
    var claudePath: String? = "/usr/bin/claude"
    /// Líneas NDJSON que `runAgentExec` emitirá por stdout al arrancar.
    var agentScript: [String] = []
    /// Líneas recibidas por stdin (prompts y control_response), para aserciones.
    private(set) var agentStdinLines: [String] = []
    /// Último comando recibido por `runAgentExec`.
    private(set) var lastAgentCommand: String?

    func locateClaude() async throws -> String? { claudePath }

    func runAgentExec(
        command: String,
        stdin: AsyncStream<[UInt8]>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws {
        lastAgentCommand = command
        for line in agentScript {
            output.yield(Array((line + "\n").utf8))
        }
        // Drena stdin (registrándolo) hasta que el llamador lo finalice con `stop()`.
        for await bytes in stdin {
            if let text = String(bytes: bytes, encoding: .utf8) {
                agentStdinLines.append(
                    contentsOf: text.split(whereSeparator: \.isNewline).map(String.init)
                )
            }
        }
        output.finish()
    }
}
