//
//  SendKeysTests.swift
//  ArgosTests
//
//  Fija el comando `tmux send-keys` que construye el broadcast: el texto debe ir
//  entrecomillado para el shell (anti-inyección en NUESTRO canal de comandos) y `Enter`
//  debe ir como argumento aparte (sin comillas) para que tmux lo interprete como tecla.
//

import Testing
@testable import Argos

@Suite("send-keys (broadcast)")
struct SendKeysTests {

    @Test("Comando básico con Enter")
    func basicWithEnter() {
        let cmd = SSHService.sendKeysCommand(session: "main", keys: "git pull", enter: true)
        #expect(cmd == "tmux send-keys -t 'main' 'git pull' Enter")
    }

    @Test("Sin Enter no añade la tecla")
    func withoutEnter() {
        let cmd = SSHService.sendKeysCommand(session: "main", keys: "ls -la", enter: false)
        #expect(cmd == "tmux send-keys -t 'main' 'ls -la'")
        #expect(!cmd.hasSuffix("Enter"))
    }

    @Test("Sesión y texto se entrecomillan con ShellQuoting (incluye comillas internas)")
    func quotesBothArguments() {
        let session = "team's-box"
        let keys = "echo 'hola'; rm -rf nope"
        let expected =
            "tmux send-keys -t \(ShellQuoting.singleQuoted(session)) "
            + ShellQuoting.singleQuoted(keys) + " Enter"
        #expect(SSHService.sendKeysCommand(session: session, keys: keys, enter: true) == expected)
    }

    @Test("Metacaracteres del shell quedan literales dentro de las comillas")
    func shellMetacharactersAreLiteral() {
        let cmd = SSHService.sendKeysCommand(session: "s", keys: "$(whoami) && reboot", enter: false)
        // Todo el payload va dentro de un único argumento entrecomillado: no puede
        // inyectar en el comando que ejecutamos por SSH.
        #expect(cmd == "tmux send-keys -t 's' '$(whoami) && reboot'")
    }
}
