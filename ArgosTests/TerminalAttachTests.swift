//
//  TerminalAttachTests.swift
//  ArgosTests
//
//  Enganche del terminal a tmux: target exacto, detección de «la sesión ya no existe»
//  (sin reintentos en bucle) y arranque idempotente del proyecto.
//

import Foundation
import Testing
@testable import Argos

@Suite("Enganche del terminal a tmux")
struct TerminalAttachTests {

    private func feed(_ chunks: [String]) -> TerminalAttachMonitor {
        var monitor = TerminalAttachMonitor()
        for chunk in chunks { monitor.consume(Array(chunk.utf8)) }
        return monitor
    }

    @Test("El attach usa target exacto para no caer en otra sesión por prefijo")
    func exactTarget() {
        #expect(TerminalAttach.command(session: "tmh/3nevados") == "tmux -u attach -t '=tmh/3nevados'")
        #expect(TerminalAttach.command(session: "it's") == #"tmux -u attach -t '=it'\''s'"#)
    }

    @Test(
        "Reconoce los mensajes de tmux de sesión inexistente",
        arguments: [
            "can't find session: tmh/3nevados\r\n",
            "session not found: web\r\n",
            "no server running on /tmp/tmux-1000/default\r\n",
            "no sessions\r\n",
        ]
    )
    func detectsMissing(message: String) {
        let monitor = feed(["Welcome to Ubuntu\r\n", "dev % exec tmux -u attach -t '=x'\r\n", message])
        #expect(monitor.sawMissingSession)
        #expect(!monitor.isAttached)
    }

    @Test("Detecta el mensaje aunque llegue partido en dos trozos")
    func detectsSplitMessage() {
        let monitor = feed(["MOTD\r\ncan't fi", "nd session: web\r\n"])
        #expect(monitor.sawMissingSession)
    }

    @Test("Una vez dentro de tmux, lo que se imprima en la sesión no cuenta")
    func ignoresOutputAfterAttach() {
        let monitor = feed(["MOTD\r\n", "\u{1B}[?1049h\u{1B}[H", "echo can't find session\r\n"])
        #expect(monitor.isAttached)
        #expect(!monitor.sawMissingSession)
    }

    @Test("Un MOTD normal no se confunde con una sesión inexistente")
    func normalMotd() {
        let monitor = feed(["Welcome to Ubuntu 24.04.5 LTS\r\n", "*** System restart required ***\r\n"])
        #expect(!monitor.sawMissingSession)
        #expect(!monitor.isAttached)
    }

    @Test("Sesión inexistente: la reconexión automática no reintenta")
    func missingSessionIsNotRetried() {
        let error = TerminalSessionMissingError(session: "web")
        #expect(!ReconnectPolicy.isRetryable(error))
        #expect(ReconnectPolicy.standard.decision(after: error, attempt: 0) == .giveUp(.needsUserAction))
    }

    @Test("El mensaje nombra la sesión")
    func errorMessage() {
        let message = TerminalSessionMissingError(session: "tmh/web").errorDescription ?? ""
        #expect(message.contains("tmh/web"))
    }

    @Test("Arrancar el proyecto no hace nada si la sesión ya existe")
    func startIsIdempotent() {
        let command = SSHService.startProjectCommand(sessionName: "tmh/web", path: "/srv/web", startupCommand: "cc --continue")
        #expect(command == "[ -d '/srv/web' ] || exit 3; "
            + "tmux has-session -t '=tmh/web' 2>/dev/null && exit 0; "
            + "tmux new-session -d -s 'tmh/web' -c '/srv/web' && "
            + "tmux send-keys -t '=tmh/web:' 'cc --continue' Enter")
    }
}
