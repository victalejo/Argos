//
//  ClaudeAgentCommand.swift
//  Argos
//
//  Construcción pura (testeable) del comando remoto que lanza `claude` headless en
//  modo stream-json sobre el canal exec de SSH. Ver memoria `argos-claude-agent-protocol`.
//
//  SEGURIDAD: el token de suscripción se pasa como asignación de entorno en la propia
//  línea de comando (`CLAUDE_CODE_OAUTH_TOKEN=…`). En un servidor compartido sería
//  visible vía `ps`/`/proc` para el MISMO usuario y root. Aceptable para servidores
//  propios; endurecerlo (token a fichero 0600) queda para una fase posterior.
//

import Foundation

enum ClaudeAgentCommand {

    /// Modo de permisos con el que arranca el agente.
    enum PermissionMode: String, Sendable {
        /// Pregunta por cada herramienta no pre-aprobada (botones en la UI).
        case `default`
        /// Auto-aprueba ediciones de archivos; pregunta el resto.
        case acceptEdits
        /// Solo lectura/exploración.
        case plan
    }

    /// Banderas base, comunes a toda invocación headless con protocolo de control.
    static let baseFlags = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--permission-prompt-tool", "stdio",
    ]

    /// Construye la línea de comando completa para ejecutar por SSH (canal exec).
    ///
    /// - Parameters:
    ///   - claudePath: ruta absoluta del binario `claude` en el servidor (de `locateClaude`).
    ///   - workingDirectory: directorio de trabajo remoto (repo) donde corre el agente.
    ///   - oauthToken: token de suscripción (`claude setup-token`). Si es `nil`/vacío, se
    ///     omite y el CLI usa la credencial de `claude login` guardada en el SERVIDOR.
    ///   - sessionID: UUID de la sesión (permite reanudar luego con `--resume`).
    ///   - permissionMode: modo de permisos inicial.
    static func build(
        claudePath: String,
        workingDirectory: String,
        oauthToken: String?,
        sessionID: String,
        permissionMode: PermissionMode = .default
    ) -> String {
        let directory = ShellQuoting.singleQuoted(workingDirectory)
        let binary = ShellQuoting.singleQuoted(claudePath)

        let flags = (baseFlags + [
            "--permission-mode", permissionMode.rawValue,
            "--session-id", sessionID,
        ]).joined(separator: " ")

        // `env -u ANTHROPIC_API_KEY` GARANTIZA que nunca se facture contra la API: sin
        // esa variable el CLI solo puede usar la suscripción (token o login del servidor).
        // Si hay token, se inyecta; si no, se usa la credencial de `claude login` del server.
        var environment = "env -u ANTHROPIC_API_KEY "
        if let oauthToken, !oauthToken.isEmpty {
            environment += "CLAUDE_CODE_OAUTH_TOKEN=\(ShellQuoting.singleQuoted(oauthToken)) "
        }

        return "cd \(directory) && \(environment)\(binary) \(flags)"
    }
}
