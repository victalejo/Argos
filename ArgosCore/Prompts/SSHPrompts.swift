//
//  SSHPrompts.swift
//  ArgosCore
//
//  Biblioteca de encargos por el canal de comandos: cambiar projects.json entero (comunes
//  y por proyecto) con cerrojo y huella, leer las variables de git del proyecto y pegar
//  un prompt en la terminal.
//

import Foundation

extension SSHService {

    /// Lee-modifica-escribe del documento entero, en fila con las demás escrituras de
    /// projects.json de esta conexión (mismos reintentos y huella que `updateProjects`).
    func updateProjectsDocument(
        _ transform: @escaping @Sendable (ProjectsDocument) throws -> ProjectsDocument
    ) async throws -> ProjectsLoadReport {
        try await SerialQueue.projects.run(key: "\(ObjectIdentifier(self))") {
            try await ProjectsUpdater.runDocument(
                read: { try await self.readHomeFile(Self.projectsRelativePath) },
                write: { data, expected in
                    try await self.writeHomeFile(
                        data, to: Self.projectsRelativePath,
                        expecting: HomeFileExpectation(expected: expected),
                        backupSuffix: Self.projectsBackupSuffix
                    )
                },
                transform: transform
            )
        }
    }

    func promptVariableValues(projectPath: String) async throws -> PromptVariables.Values {
        let client = try await connectedClient()
        let result = try await capture(client, command: PromptVariables.command(projectPath: projectPath))
        if result.exitCode == PromptVariables.missingFolderExitCode { throw ProjectError.missingFolder(projectPath) }
        return PromptVariables.parse(result.stdout)
    }

    func pastePromptToTerminal(session: String, window: Int?, text: String) async throws {
        let clean = PromptText.sanitizedForPaste(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PromptSendError.empty }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = PromptPasteScript.relativePath(token: token)
        try await writeHomeFilePrivately(Data(clean.utf8), to: path)
        let client = try await connectedClient()
        let result = try await capture(client, command: PromptPasteScript.command(session: session, window: window, relativePath: path))
        switch result.exitCode {
        case 0: return
        case PromptPasteScript.missingPaneExitCode: throw PromptSendError.noPane
        case PromptPasteScript.notClaudeExitCode: throw PromptSendError.notClaude
        default: throw PromptSendError.tmux
        }
    }
}

/// Rellena las variables de un prompt con lo que diga el servidor. Si no se puede leer
/// (sin red, sin git), se rellenan con «sin datos»: el prompt se puede enviar igual.
enum PromptExpansion {
    static func expand(_ text: String, service: any SSHServicing, projectPath: String) async -> String {
        guard PromptVariables.containsVariables(text) else { return text }
        do {
            let values = try await service.promptVariableValues(projectPath: projectPath)
            return PromptVariables.substitute(text, values: values)
        } catch {
            Log.ssh.notice("Biblioteca: no se pudieron leer las variables de git: \(error.userMessage, privacy: .public)")
            return PromptVariables.substitute(text, values: PromptVariables.Values())
        }
    }
}
