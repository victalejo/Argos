//
//  SSHProjects.swift
//  Argos
//
//  Proyectos por el CANAL DE COMANDOS: leer/guardar `~/.config/argos/projects.json`,
//  arrancar la sesión tmux de un proyecto en su carpeta (lanzando el comando de
//  arranque) y detenerla. Los targets de tmux usan `=nombre` (coincidencia EXACTA):
//  sin '=', tmux cae a coincidencia por prefijo y podría actuar sobre OTRA sesión.
//

import Foundation

extension SSHService {

    static let projectsRelativePath = ".config/argos/projects.json"

    /// Exit code con el que `startProjectCommand` indica que la carpeta no existe.
    static let missingFolderExitCode = 3

    /// Target EXACTO de sesión para tmux (`'=nombre'`), entrecomillado para el shell.
    static func exactSessionTarget(_ name: String) -> String {
        ShellQuoting.singleQuoted("=\(name)")
    }

    /// Crea la sesión del proyecto en su carpeta y teclea el comando de arranque en el
    /// shell interactivo (con `send-keys`, así funcionan alias como `cc`).
    static func startProjectCommand(sessionName: String, path: String, startupCommand: String?) -> String {
        let quotedPath = ShellQuoting.singleQuoted(path)
        var command = "[ -d \(quotedPath) ] || exit \(missingFolderExitCode); "
            + "tmux new-session -d -s \(ShellQuoting.singleQuoted(sessionName)) -c \(quotedPath)"
        if let startupCommand {
            // `=nombre:` = ventana/panel activo de la sesión exacta.
            command += " && tmux send-keys -t \(ShellQuoting.singleQuoted("=\(sessionName):")) "
                + "\(ShellQuoting.singleQuoted(startupCommand)) Enter"
        }
        return command
    }

    static func stopSessionCommand(sessionName: String) -> String {
        "tmux kill-session -t \(exactSessionTarget(sessionName))"
    }

    static let firstPanePathsCommand =
        "tmux list-panes -a -F '#{window_index}|#{pane_index}|#{pane_current_path}|#{session_name}' 2>/dev/null"

    // MARK: - Fichero de proyectos

    func loadProjects() async throws -> [Project] {
        try ProjectsFile.decode(try await readHomeFile(Self.projectsRelativePath)).projects
    }

    func saveProjects(_ projects: [Project]) async throws {
        let data = try ProjectsFile(projects: projects).encoded()
        try await writeHomeFilePrivately(data, to: Self.projectsRelativePath, backup: true)
    }

    // MARK: - Sesiones de proyecto

    /// Carpeta del primer panel de cada sesión (para importar sesiones como proyectos).
    func sessionFirstPanePaths() async throws -> [String: String] {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.firstPanePathsCommand)
        guard result.exitCode == 0 else { return [:] }
        return ProjectListing.firstPanePaths(listPanesOutput: result.stdout)
    }

    func startProject(sessionName: String, path: String, startupCommand: String?) async throws {
        let client = try await connectedClient()
        let command = Self.startProjectCommand(sessionName: sessionName, path: path, startupCommand: startupCommand)
        let result = try await capture(client, command: command)
        if result.exitCode == Self.missingFolderExitCode { throw ProjectError.missingFolder(path) }
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? "No se pudo abrir el proyecto." : message
            )
        }
    }

    func stopSession(named sessionName: String) async throws {
        _ = try await runChecked(
            Self.stopSessionCommand(sessionName: sessionName),
            failureMessage: "No se pudo detener la sesión '\(sessionName)'."
        )
    }
}
