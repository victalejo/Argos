//
//  SSHAgentExec.swift
//  Argos
//
//  Extensión de `SSHService` para el panel de agente de Claude Code: localiza el
//  binario remoto y ejecuta `claude` headless por un canal exec BIDIRECCIONAL.
//
//  A diferencia del PTY del terminal (`SSHTerminalSession`), aquí se usa
//  `SSHClient.withExec` (RFC 4254, 8-bit safe, sin secuencias de terminal): ideal
//  para el stream-json. Reutiliza el mismo `connectedClient()` autenticado (TOFU +
//  Keychain + heartbeat). Solo se reenvía **stdout** al consumidor (es donde viaja el
//  NDJSON); stderr se registra para diagnóstico.
//

import Foundation
import os
import Citadel
import NIOCore                 // ByteBuffer
import NIOConcurrencyHelpers   // NIOLockedValueBox

/// Error del proceso `claude` remoto que incluye su stderr (mucho más útil que un
/// `ChannelError` genérico: aquí aparece "not logged in", "unknown option", etc.).
struct AgentExecError: LocalizedError {
    let message: String
    var errorDescription: String? {
        "El agente de Claude se cerró. Detalle del servidor:\n\(message)"
    }
}

/// Estado de autenticación de `claude` en un servidor (de `claude auth status --json`).
struct ClaudeAuthStatus: Sendable, Equatable {
    let loggedIn: Bool
    /// Tipo de suscripción ("max", "pro", …) si está logueado con suscripción.
    let subscriptionType: String?
    let email: String?

    /// `true` si usa una suscripción de pago (no API/console).
    var usesSubscription: Bool {
        guard let subscriptionType else { return false }
        return !subscriptionType.isEmpty
    }
}

extension SSHService {

    /// Localiza `claude` en el servidor de forma robusta: prueba la shell de login del
    /// usuario y varias shells comunes (para cargar el PATH donde vive `claude`, p. ej.
    /// `~/.local/bin`, nvm…), y si eso falla, comprueba rutas de instalación conocidas.
    /// Tolera el ruido que los perfiles de login imprimen en stdout (toma la última línea
    /// que sea una ruta absoluta).
    func locateClaude() async throws -> String? {
        let client = try await connectedClient()
        // Nota: el `command -v claude` de cada shell de login puede ir precedido del MOTD/
        // perfil; `tail -n1` se queda con la ruta. El `case /*` filtra a rutas absolutas.
        let script = """
        for s in "$SHELL" bash zsh sh; do
          p=$("$s" -lc 'command -v claude' 2>/dev/null | tail -n1)
          case "$p" in /*) echo "$p"; exit 0;; esac
        done
        for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
                 "$HOME/.claude/bin/claude" "$HOME/bin/claude" \
                 "/usr/local/bin/claude" "/opt/homebrew/bin/claude" "/usr/bin/claude"; do
          [ -x "$c" ] && { echo "$c"; exit 0; }
        done
        exit 1
        """
        let result = try await capture(client, command: script)
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    /// Consulta `claude auth status --json` en el servidor. Devuelve `nil` si `claude` no
    /// está instalado. La salida JSON incluye `loggedIn`, `subscriptionType`, `email`.
    func claudeAuthStatus() async throws -> ClaudeAuthStatus? {
        guard let claudePath = try await locateClaude() else { return nil }
        let client = try await connectedClient()
        let command = "\(ShellQuoting.singleQuoted(claudePath)) auth status --json"
        let result = try await capture(client, command: command)

        // Extrae el objeto JSON (por si hay ruido de perfil/avisos antes o después).
        guard let json = Self.extractJSONObject(result.stdout),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawAuthStatus.self, from: data) else {
            // Sin JSON parseable: lo tratamos como "no logueado" (p. ej. error del CLI).
            return ClaudeAuthStatus(loggedIn: false, subscriptionType: nil, email: nil)
        }
        return ClaudeAuthStatus(
            loggedIn: raw.loggedIn ?? false,
            subscriptionType: raw.subscriptionType,
            email: raw.email
        )
    }

    /// Forma cruda del JSON de `claude auth status --json` (campos opcionales).
    private struct RawAuthStatus: Decodable {
        let loggedIn: Bool?
        let subscriptionType: String?
        let email: String?
    }

    /// Extrae la subcadena del primer `{` al último `}` (descarta ruido de perfil/avisos).
    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }

    /// Ejecuta un comando por canal exec bidireccional. Reenvía stdout a `output` y
    /// escribe en stdin lo que llegue por `stdin`. Termina cuando el proceso remoto
    /// cierra (EOF), cuando `stdin` se finaliza, o al cancelarse la tarea.
    func runAgentExec(
        command: String,
        stdin: AsyncStream<[UInt8]>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws {
        let client = try await connectedClient()
        defer { output.finish() }

        // stderr acumulado (thread-safe): si el proceso muere, lo mostramos en el error
        // en vez de un `ChannelError` genérico.
        let stderrBox = NIOLockedValueBox("")

        do {
            try await client.withExec(command) { inbound, outbound in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Proceso remoto -> consumidor: solo stdout (donde va el NDJSON).
                    group.addTask {
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let buffer):
                                if let bytes = buffer.getBytes(
                                    at: buffer.readerIndex,
                                    length: buffer.readableBytes
                                ), !bytes.isEmpty {
                                    output.yield(bytes)
                                }
                            case .stderr(let buffer):
                                if let bytes = buffer.getBytes(
                                    at: buffer.readerIndex,
                                    length: buffer.readableBytes
                                ), let text = String(bytes: bytes, encoding: .utf8),
                                   !text.isEmpty {
                                    stderrBox.withLockedValue { $0 += text }
                                    Log.agent.debug("claude stderr: \(text, privacy: .public)")
                                }
                            }
                        }
                    }

                    // Consumidor -> stdin del proceso remoto (prompts y control_response).
                    group.addTask {
                        do {
                            for await bytes in stdin {
                                try await outbound.write(ByteBuffer(bytes: bytes))
                            }
                        } catch is CancellationError {
                            // Parada normal.
                        } catch {
                            Log.agent.debug("Fin de escritura a claude: \(String(describing: error), privacy: .public)")
                        }
                    }

                    // En cuanto una rama termina (EOF del proceso o cancelación), paramos
                    // la otra; `withExec` cierra el canal al retornar.
                    _ = try await group.next()
                    group.cancelAll()
                }
            }
        } catch {
            // Si claude dejó algo en stderr, es mucho más útil que el error de canal.
            let stderr = stderrBox.withLockedValue { $0 }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty {
                throw AgentExecError(message: String(stderr.suffix(600)))
            }
            throw error
        }
    }
}
