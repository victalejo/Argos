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
        "tmux -u list-panes -a -F '#{window_index}|#{pane_index}|#{pane_current_path}|#{session_name}' 2>/dev/null"

    // MARK: - Fichero de proyectos

    static let projectsBackupSuffix = ".argos-backup"
    static let projectsDamagedSuffix = ".argos-damaged"

    func loadProjects() async throws -> [Project] {
        try await loadProjectsReport().projects
    }

    func loadProjectsReport() async throws -> ProjectsLoadReport {
        ProjectsLoadReport(document: try ProjectsDocument.parse(try await readHomeFile(Self.projectsRelativePath)))
    }

    /// Sustituye la lista entera (conservando lo desconocido de cada proyecto por `id`).
    func saveProjects(_ projects: [Project]) async throws {
        _ = try await updateProjects { _ in projects }
    }

    /// Lee-modifica-escribe con comprobación de huella y reintentos (`ProjectsUpdater`),
    /// en fila con las demás escrituras de projects.json de este servidor en esta app.
    func updateProjects(
        _ transform: @escaping @Sendable ([Project]) throws -> [Project]
    ) async throws -> ProjectsLoadReport {
        try await SerialQueue.projects.run(key: projectsQueueKey) {
            try await ProjectsUpdater.run(
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

    /// Vuelve a la copia `.argos-backup` (la deja cada escritura). El archivo actual se
    /// guarda en `.argos-damaged` por si hiciera falta. Lanza si no hay copia o si
    /// tampoco se puede leer.
    func restoreProjectsBackup() async throws -> ProjectsLoadReport {
        try await SerialQueue.projects.run(key: projectsQueueKey) {
            let backupPath = Self.projectsRelativePath + Self.projectsBackupSuffix
            for _ in 1...ProjectsUpdater.maxAttempts {
                let current = try await self.readHomeFile(Self.projectsRelativePath)
                let backup = try await self.readHomeFile(backupPath)
                guard !backup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError.noBackup }
                guard let document = try? ProjectsDocument.parse(backup) else { throw ProjectError.invalidBackup }
                let outcome = try await self.writeHomeFile(
                    Data(backup.utf8), to: Self.projectsRelativePath,
                    expecting: HomeFileExpectation(expected: ProjectsUpdater.expectedFingerprint(of: current)),
                    backupSuffix: Self.projectsDamagedSuffix
                )
                if outcome == .written {
                    Log.store.notice("projects.json restaurado desde la copia anterior.")
                    return ProjectsLoadReport(document: document)
                }
            }
            throw ProjectError.writeConflict
        }
    }

    /// Una fila por conexión (entre conexiones o dispositivos protege la huella).
    private nonisolated var projectsQueueKey: String { "\(ObjectIdentifier(self))" }

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
                message: message.isEmpty ? String(localized: "No se pudo abrir el proyecto.") : message
            )
        }
    }

    func stopSession(named sessionName: String) async throws {
        _ = try await runChecked(
            Self.stopSessionCommand(sessionName: sessionName),
            failureMessage: String(localized: "No se pudo detener la sesión '\(sessionName)'.")
        )
    }
}
