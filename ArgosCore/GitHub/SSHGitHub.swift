//
//  SSHGitHub.swift
//  ArgosCore
//
//  GitHub por el `gh` del servidor, con comandos cortos del canal de comandos. Los
//  comandos los arma `GitHubCommands` y la salida la interpreta `GitHubParser`.
//

import Foundation

extension SSHService {

    func gitHubStatus(root: String) async throws -> GitHubStatusResult {
        let client = try await connectedClient()
        let result = try await capture(client, command: GitHubCommands.status(root: root))
        return GitHubParser.parseStatus(result.stdout)
    }

    func gitHubCreatePullRequest(root: String, draft: Bool) async throws -> URL? {
        let output = try await runGitHub(GitHubCommands.createPullRequest(root: root, draft: draft))
        return GitHubParser.createdPullRequestURL(output)
    }

    func gitHubRerunFailed(root: String, runID: Int) async throws {
        _ = try await runGitHub(GitHubCommands.rerunFailed(root: root, runID: runID))
    }

    func gitHubRepositories() async throws -> GitHubParser.RepositoriesResult {
        let client = try await connectedClient()
        let result = try await capture(client, command: GitHubCommands.repositories())
        return GitHubParser.parseRepositories(result.stdout)
    }

    func gitHubClone(_ request: GitHubCloneRequest) async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: GitHubCommands.clone(request))
        if let refusal = GitHubParser.cloneRefusal(result.stdout) { throw GitCommandError(message: refusal) }
        guard result.exitCode == 0 else {
            throw GitCommandError.from(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }
        guard let path = GitHubParser.clonedPath(result.stdout) else {
            throw GitCommandError(message: "El clonado terminó pero no se encontró la carpeta.")
        }
        return path
    }

    /// Ejecuta un comando `gh` (con `2>&1`) y devuelve su salida; lanza si falla.
    private func runGitHub(_ command: String) async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            throw GitCommandError.from(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }
        return result.stdout
    }
}
