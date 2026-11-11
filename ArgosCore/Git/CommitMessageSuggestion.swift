//
//  CommitMessageSuggestion.swift
//  ArgosCore
//
//  «Sugerir mensaje» del panel «Cambios»: Claude Code, EN EL SERVIDOR, lee el diff de los
//  archivos marcados y los últimos mensajes del repo, y propone un mensaje de commit con
//  el mismo estilo e idioma. Usa la suscripción (token por stdin, nunca en la línea de
//  comandos; `env -u ANTHROPIC_API_KEY` impide facturar contra la API) y un modelo rápido.
//

import Foundation

enum CommitMessageSuggestion {

    /// Modelo de la sugerencia: rápido y barato, de sobra para un mensaje de commit.
    static let model = "haiku"
    /// Bytes máximos del prompt (un diff enorme se recorta: basta con el principio).
    static let promptByteLimit = 120_000
    /// Marcador del código de salida de `claude` (la salida mezcla stdout y stderr).
    static let exitMarker = "ARGOS_CM_EXIT:"
    /// Tiempo máximo de espera de la sugerencia.
    static let timeout: Duration = .seconds(120)

    static let instructions = """
    Escribe el mensaje de commit para los cambios de abajo. Sigue el estilo y el idioma de \
    los mensajes recientes del repositorio (por ejemplo, Conventional Commits si los usan). \
    Primera línea de 72 caracteres como máximo. Si hace falta, deja una línea en blanco y \
    añade un cuerpo breve que explique el porqué. Responde SOLO con el mensaje: sin \
    comillas, sin bloques de código y sin comentarios.
    """

    private static func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }

    /// Script (sin envolver en `sh -c`: lo envuelve `runAgentExec`). La primera línea de
    /// stdin es el token (vacía = credencial de `claude login` del servidor).
    static func command(claudePath: String, root: String, changes: [GitFileChange], hasCommits: Bool) -> String {
        let git = "\(GitCommands.git(root)) -c core.quotepath=off"
        let diff = "\(git) diff --no-color --no-ext-diff"
        let tracked = changes.filter { !$0.isUntracked }
        let trackedPaths = GitCommands.commitPaths(tracked).map(q).joined(separator: " ")
        var parts: [String] = []
        if !tracked.isEmpty {
            parts.append(hasCommits
                ? "\(diff) -M HEAD -- \(trackedPaths)"
                : "\(diff) --cached -- \(trackedPaths); \(diff) -- \(trackedPaths)")
        }
        for change in changes where change.isUntracked {
            parts.append("\(diff) --no-index -- /dev/null \(q(change.path))")
        }
        let diffs = parts.map { "\($0) 2>/dev/null" }.joined(separator: "\n  ")
        return """
        cd \(q(root)) || exit 1
        IFS= read -r ARGOS_OAUTH; [ -n "$ARGOS_OAUTH" ] && export CLAUDE_CODE_OAUTH_TOKEN="$ARGOS_OAUTH"; unset ARGOS_OAUTH
        {
          printf '%s\\n\\n' \(q(instructions))
          echo '--- Mensajes recientes del repositorio ---'
          \(GitCommands.git(root)) log -15 --format=%s 2>/dev/null
          echo
          echo '--- Cambios ---'
          \(diffs.isEmpty ? "true" : diffs)
        } | head -c \(promptByteLimit) | env -u ANTHROPIC_API_KEY \(q(claudePath)) -p --model \(model) --output-format text 2>&1
        rc=$?
        printf '\\n%s%s\\n' '\(exitMarker)' "$rc"
        """
    }

    /// Mensaje limpio a partir de la salida, o el error de `claude` (salida ≠ 0).
    static func parse(_ output: String) throws -> String {
        guard let range = output.range(of: exitMarker, options: .backwards) else {
            throw GitCommandError(message: "Claude no respondió (la conexión se cortó).")
        }
        let code = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        let text = String(output[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0 else {
            let detail = text.isEmpty ? "claude terminó con código \(code)." : String(text.suffix(600))
            throw GitCommandError(message: detail)
        }
        let message = clean(text)
        guard !message.isEmpty else { throw GitCommandError(message: "Claude no propuso ningún mensaje.") }
        return message
    }

    /// Quita lo que a veces añade el modelo: bloques de código, comillas o un «Mensaje:».
    static func clean(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Mensaje de commit:", "Commit message:", "Mensaje:"] where message.hasPrefix(prefix) {
            message = String(message.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("«", "»"), ("'", "'"), ("`", "`")]
        where message.hasPrefix(open) && message.hasSuffix(close) && message.count > 2 {
            message = String(message.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message
    }

    /// Pide la sugerencia al `claude` del servidor y devuelve el mensaje.
    static func suggest(
        service: any SSHServicing, root: String, changes: [GitFileChange], hasCommits: Bool, oauthToken: String?
    ) async throws -> String {
        guard let claude = try await service.locateClaude() else {
            throw GitCommandError(message: "Claude Code no está instalado en el servidor.")
        }
        let command = command(claudePath: claude, root: root, changes: changes, hasCommits: hasCommits)
        // stdin queda ABIERTO: si se cerrara, `runAgentExec` dejaría de leer la respuesta.
        let (stdin, input) = AsyncStream<[UInt8]>.makeStream()
        input.yield(ClaudeAgentCommand.tokenLine(oauthToken))
        let (output, sink) = AsyncStream<[UInt8]>.makeStream()
        let run = Task { try await service.runAgentExec(command: command, stdin: stdin, output: sink) }
        defer { run.cancel(); input.finish() }
        let collected = try await withThrowingTaskGroup(of: [UInt8]?.self) { group in
            group.addTask {
                // Se para en cuanto llega la línea del código de salida (no hace falta el EOF).
                var bytes: [UInt8] = []
                for await chunk in output {
                    bytes += chunk
                    if let range = String(decoding: bytes, as: UTF8.self).range(of: exitMarker, options: .backwards),
                       String(decoding: bytes, as: UTF8.self)[range.upperBound...].contains("\n") {
                        break
                    }
                }
                return bytes
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let collected else { throw GitCommandError(message: "Claude tardó demasiado en responder.") }
        // Con la respuesta ya leída se cierra stdin: así `runAgentExec` termina y se puede
        // esperar su resultado (esperarlo con stdin abierto se quedaría colgado).
        input.finish()
        if let error = await run.result.failure { throw error }
        return try parse(String(decoding: collected, as: UTF8.self))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
