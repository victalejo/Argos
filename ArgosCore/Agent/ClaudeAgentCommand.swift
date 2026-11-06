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
        /// Todos los permisos: ejecuta cualquier herramienta sin preguntar.
        /// (El CLI lo rechaza si el usuario remoto es root.)
        case bypassPermissions
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
        permissionMode: PermissionMode = .bypassPermissions
    ) -> String {
        let directory = cdTarget(for: workingDirectory)
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

        // Antes de nada se anuncia el PID: `exec` conserva el PID de la shell, así que es
        // el del propio `claude`. Permite matarlo al cerrar la pestaña (sin huérfanos).
        let announcePID = "echo \"{\\\"type\\\":\\\"\(pidEventType)\\\",\\\"pid\\\":$$}\""
        return "cd \(directory) && \(announcePID) && exec \(environment)\(binary) \(flags)"
    }

    /// Tipo de la línea NDJSON con la que el comando anuncia el PID del agente.
    static let pidEventType = "argos_pid"

    /// PID anunciado por el comando, si `line` es esa línea.
    static func announcedPID(in line: String) -> Int32? {
        guard line.contains(pidEventType),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == pidEventType,
              let pid = object["pid"] as? Int, pid > 1, pid <= Int(Int32.max)
        else { return nil }
        return Int32(pid)
    }

    /// Construye el argumento de `cd` expandiendo `~` correctamente. `~` NO se expande
    /// entre comillas simples, así que se traduce a `"$HOME"` y solo se entrecomilla el
    /// resto de la ruta (anti-inyección).
    static func cdTarget(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" || trimmed.isEmpty {
            return "\"$HOME\""
        }
        if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            return "\"$HOME\"/\(ShellQuoting.singleQuoted(rest))"
        }
        return ShellQuoting.singleQuoted(trimmed)
    }
}
