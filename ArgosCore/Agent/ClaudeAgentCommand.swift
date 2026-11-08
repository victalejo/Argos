//
//  ClaudeAgentCommand.swift
//  Argos
//
//  Construcción pura (testeable) del comando remoto que lanza `claude` headless en
//  modo stream-json sobre el canal exec de SSH. Ver memoria `argos-claude-agent-protocol`.
//
//  SEGURIDAD: el token de suscripción viaja por stdin (ver `tokenLine`) y se exporta con
//  un builtin. La línea de comandos la puede leer cualquier usuario del servidor (`ps`),
//  así que el token nunca va en ella.
//

import Foundation

enum ClaudeAgentCommand {

    /// Modo de permisos con el que arranca el agente.
    enum PermissionMode: String, CaseIterable, Sendable {
        /// Todos los permisos: ejecuta cualquier herramienta sin preguntar.
        /// (El CLI lo rechaza si el usuario remoto es root: ver `modeArgument`.)
        case bypassPermissions
        /// Auto-aprueba ediciones de archivos; pregunta el resto.
        case acceptEdits
        /// Pregunta por cada herramienta no pre-aprobada (botones en la UI).
        case `default`
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
    /// La PRIMERA línea de stdin debe ser `tokenLine(_:)`: con token, se exporta; vacía, el
    /// CLI usa la credencial de `claude login` guardada en el SERVIDOR.
    ///
    /// - Parameters:
    ///   - claudePath: ruta absoluta del binario `claude` en el servidor (de `locateClaude`).
    ///   - workingDirectory: directorio de trabajo remoto (repo) donde corre el agente.
    ///   - sessionID: UUID de la sesión (permite reanudar luego con `--resume`).
    ///   - permissionMode: modo de permisos inicial.
    static func build(
        claudePath: String,
        workingDirectory: String,
        sessionID: String,
        permissionMode: PermissionMode = .bypassPermissions
    ) -> String {
        let directory = cdTarget(for: workingDirectory)
        let binary = ShellQuoting.singleQuoted(claudePath)

        let flags = (baseFlags + [
            "--permission-mode", modeArgument(permissionMode),
            "--session-id", sessionID,
        ]).joined(separator: " ")

        // `env -u ANTHROPIC_API_KEY` GARANTIZA que nunca se facture contra la API: sin
        // esa variable el CLI solo puede usar la suscripción (token o login del servidor).
        // `read` no consume más allá de la primera línea: el resto de stdin es para claude.
        let readToken = "IFS= read -r ARGOS_OAUTH; "
            + "[ -n \"$ARGOS_OAUTH\" ] && export CLAUDE_CODE_OAUTH_TOKEN=\"$ARGOS_OAUTH\"; unset ARGOS_OAUTH"

        // Antes de nada se anuncia el PID: `exec` conserva el PID de la shell, así que es
        // el del propio `claude`. Permite matarlo al cerrar la pestaña (sin huérfanos).
        let announcePID = "echo \"{\\\"type\\\":\\\"\(pidEventType)\\\",\\\"pid\\\":$$}\""
        return "cd \(directory) && \(announcePID) && { \(readToken); exec env -u ANTHROPIC_API_KEY \(binary) \(flags); }"
    }

    /// Primera línea de stdin del comando: el token de suscripción, o vacía si no hay.
    /// Sin saltos de línea: lo que siguiera a uno le llegaría a claude como un prompt.
    static func tokenLine(_ oauthToken: String?) -> [UInt8] {
        let token = (oauthToken ?? "").filter { !$0.isNewline && !$0.isWhitespace }
        return Array((token + "\n").utf8)
    }

    /// Valor de `--permission-mode`. El CLI rechaza `bypassPermissions` con root y el agente
    /// no llegaría a arrancar, así que con root se pregunta cada acción.
    private static func modeArgument(_ mode: PermissionMode) -> String {
        guard mode == .bypassPermissions else { return mode.rawValue }
        return "\"$([ \"$(id -u)\" = 0 ] && echo \(PermissionMode.default.rawValue) || echo \(mode.rawValue))\""
    }

    /// Tipo de la línea NDJSON con la que el comando anuncia el PID del agente.
    /// Invocación de `claude` para un agente PERSISTENTE (ver `PersistentAgentScript`):
    /// sin `cd` ni anuncio de PID (los pone el lanzador) y con `--replay-user-messages`,
    /// para que los prompts queden en el log y una reconexión reconstruya la conversación.
    /// `resume`: reanuda una conversación existente (el proceso anterior terminó).
    /// El token OAuth NO va aquí: el lanzador lo recibe por stdin y lo exporta.
    static func persistent(
        claudePath: String,
        sessionID: String,
        resume: Bool,
        permissionMode: PermissionMode = .default
    ) -> String {
        let flags = (baseFlags + [
            "--replay-user-messages",
            "--permission-mode", modeArgument(permissionMode),
            resume ? "--resume" : "--session-id", sessionID,
        ]).joined(separator: " ")
        return "env -u ANTHROPIC_API_KEY \(ShellQuoting.singleQuoted(claudePath)) \(flags)"
    }

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
