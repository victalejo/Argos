//
//  TmuxErrorClassificationTests.swift
//  ArgosTests
//
//  Clasificación de la salida de error de tmux: decide entre "lista vacía"
//  (servidor sin sesiones) y "tmux no instalado" (ofrecer instalación).
//

import Testing
@testable import Argos

@Suite("Clasificación de errores tmux")
struct TmuxErrorClassificationTests {

    @Test("Marcadores de 'no hay servidor' => lista vacía", arguments: [
        "no server running on /tmp/tmux-1000/default",
        "error connecting to /tmp/tmux-1000/default (No such file or directory)",
        "failed to connect to server",
        "no sessions"
    ])
    func noServer(stderr: String) {
        #expect(SSHService.indicatesNoTmuxServer(stdout: "", stderr: stderr))
    }

    @Test("Salida normal NO se confunde con 'no hay servidor'")
    func notNoServer() {
        #expect(!SSHService.indicatesNoTmuxServer(stdout: "main|1|0|1700000000", stderr: ""))
    }

    @Test("'command not found' => tmux no instalado")
    func notInstalledByText() {
        #expect(SSHService.indicatesTmuxNotInstalled(
            stdout: "", stderr: "bash: tmux: command not found", exitCode: 127))
    }

    @Test("Exit 127 mencionando tmux => no instalado")
    func notInstalledByExitCode() {
        #expect(SSHService.indicatesTmuxNotInstalled(
            stdout: "", stderr: "tmux: not found", exitCode: 127))
    }

    @Test("Un error real (no relacionado con tmux) NO se clasifica como tmux ausente")
    func unrelatedError() {
        #expect(!SSHService.indicatesTmuxNotInstalled(
            stdout: "", stderr: "permission denied", exitCode: 1))
    }
}
