//
//  ClaudeAgentCommandTests.swift
//  ArgosTests
//
//  Verifica la construcción del comando remoto: flags del protocolo, modo de
//  permisos, cwd y, sobre todo, las garantías de seguridad (entrecomillado
//  anti-inyección y neutralización de ANTHROPIC_API_KEY).
//

import Testing
import Foundation
@testable import Argos

struct ClaudeAgentCommandTests {

    @Test("incluye las banderas del protocolo de control")
    func includesProtocolFlags() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/usr/bin/claude",
            workingDirectory: "/home/u/repo",
            oauthToken: "tok",
            sessionID: "11111111-1111-1111-1111-111111111111"
        )
        #expect(command.contains("--input-format stream-json"))
        #expect(command.contains("--output-format stream-json"))
        #expect(command.contains("--permission-prompt-tool stdio"))
        #expect(command.contains("--permission-mode default"))
        #expect(command.contains("--session-id 11111111-1111-1111-1111-111111111111"))
    }

    @Test("neutraliza ANTHROPIC_API_KEY e inyecta el token de suscripción")
    func usesSubscriptionToken() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/usr/bin/claude",
            workingDirectory: "/repo",
            oauthToken: "secreto",
            sessionID: "s"
        )
        #expect(command.contains("env -u ANTHROPIC_API_KEY"))
        #expect(command.contains("CLAUDE_CODE_OAUTH_TOKEN='secreto'"))
    }

    @Test("entrecomilla cwd, token y binario contra inyección de shell")
    func quotesAgainstInjection() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/opt/claude",
            workingDirectory: "/tmp/a b; rm -rf ~",
            oauthToken: "x'; echo hi",
            sessionID: "s"
        )
        // El cwd peligroso queda como un único argumento entrecomillado.
        #expect(command.contains("cd '/tmp/a b; rm -rf ~'"))
        // La comilla simple del token se escapa con el patrón '\'' (no rompe el quoting).
        #expect(command.contains(#"CLAUDE_CODE_OAUTH_TOKEN='x'\''; echo hi'"#))
        // No debe existir un `rm -rf` fuera de las comillas (no se "escapó" del literal).
        #expect(!command.contains("&& rm -rf"))
    }

    @Test("sin token: usa el login del servidor y nunca la API")
    func noTokenUsesServerLogin() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/usr/bin/claude",
            workingDirectory: "/repo",
            oauthToken: nil,
            sessionID: "s"
        )
        // Siempre quita la API key (garantiza facturación a la suscripción).
        #expect(command.contains("env -u ANTHROPIC_API_KEY"))
        // Sin token: no se inyecta la variable (se usa la credencial de `claude login`).
        #expect(!command.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    @Test("token vacío se trata como ausente")
    func emptyTokenOmitted() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/c", workingDirectory: "/r", oauthToken: "", sessionID: "s"
        )
        #expect(!command.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }

    @Test("el modo de permisos se refleja en la bandera")
    func permissionModeFlag() {
        let command = ClaudeAgentCommand.build(
            claudePath: "/c",
            workingDirectory: "/r",
            oauthToken: "t",
            sessionID: "s",
            permissionMode: .acceptEdits
        )
        #expect(command.contains("--permission-mode acceptEdits"))
    }
}
