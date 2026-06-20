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
import NIOCore   // ByteBuffer

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

    /// Localiza `claude` en el servidor probando shells de login (el binario suele
    /// estar en `~/.local/bin`, nvm, etc., fuera del PATH de un exec no interactivo).
    func locateClaude() async throws -> String? {
        let client = try await connectedClient()
        let probes = [
            "bash -lc 'command -v claude'",
            "zsh -lc 'command -v claude'",
            "command -v claude",
        ]
        for probe in probes {
            let result = try await capture(client, command: probe)
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0, !path.isEmpty {
                return path.split(whereSeparator: \.isNewline).first.map(String.init) ?? path
            }
        }
        return nil
    }

    /// Consulta `claude auth status --json` en el servidor. Devuelve `nil` si `claude` no
    /// está instalado. La salida JSON incluye `loggedIn`, `subscriptionType`, `email`.
    func claudeAuthStatus() async throws -> ClaudeAuthStatus? {
        guard let claudePath = try await locateClaude() else { return nil }
        let client = try await connectedClient()
        let command = "\(ShellQuoting.singleQuoted(claudePath)) auth status --json"
        let result = try await capture(client, command: command)

        guard let data = result.stdout.data(using: .utf8),
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
    }
}
