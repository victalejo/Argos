//
//  SSHGit.swift
//  ArgosCore
//
//  Operaciones git del panel «Cambios» por el canal de comandos de la conexión
//  compartida (comandos cortos). Los comandos los arma `GitCommands`.
//

import Foundation

/// Fallo de una operación git, con el mensaje de git para mostrarlo tal cual.
struct GitCommandError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    /// Mensaje útil a partir de la salida: git suele explicar el problema en las
    /// últimas líneas (p. ej. «Please tell me who you are», «rejected»).
    static func from(stdout: String, stderr: String, exitCode: Int) -> GitCommandError {
        let text = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let text else { return GitCommandError(message: "git terminó con código \(exitCode).") }
        let lines = text.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
        return GitCommandError(message: lines)
    }
}

extension SSHService {

    func gitStatus(at path: String) async throws -> GitStatusResult {
        let client = try await connectedClient()
        let result = try await capture(client, command: GitCommands.status(path: path))
        return GitStatusParser.parse(result.stdout)
    }

    func gitDiff(root: String, change: GitFileChange, hasCommits: Bool) async throws -> GitFileDiff {
        let client = try await connectedClient()
        let command = GitCommands.diff(root: root, change: change, hasCommits: hasCommits)
        let result = try await capture(client, command: command)
        // `head` es el último del pipe: el código es el suyo. Error solo si no hubo salida.
        if result.stdout.isEmpty, !result.stderr.isEmpty {
            throw GitCommandError.from(stdout: "", stderr: result.stderr, exitCode: result.exitCode)
        }
        let truncated = result.stdout.utf8.count > GitCommands.diffByteLimit
        return GitDiffParser.parse(result.stdout, truncated: truncated)
    }

    func gitDiscard(root: String, change: GitFileChange) async throws {
        _ = try await runGit(GitCommands.discard(root: root, change: change))
    }

    func gitCommit(root: String, message: String, changes: [GitFileChange]) async throws -> String {
        try await runGit(GitCommands.commit(root: root, message: message, changes: changes))
    }

    func gitPush(root: String, hasUpstream: Bool) async throws -> String {
        try await runGit(GitCommands.push(root: root, hasUpstream: hasUpstream))
    }

    func gitPull(root: String) async throws -> String {
        try await runGit(GitCommands.pull(root: root))
    }

    func gitSummaries(paths: [String]) async throws -> [String: GitRepoSummary] {
        guard !paths.isEmpty else { return [:] }
        let client = try await connectedClient()
        let result = try await capture(client, command: GitSummaryCommands.summaries(paths: paths))
        return GitSummaryParser.parse(result.stdout, paths: paths)
    }

    /// Ejecuta un comando git y devuelve su salida (resumida); lanza si falla.
    private func runGit(_ command: String) async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            throw GitCommandError.from(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
