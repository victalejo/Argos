//
//  SSHCheckpoints.swift
//  ArgosCore
//
//  Puntos de restauración por el canal de comandos de la conexión compartida. Los
//  comandos los arma `CheckpointCommands`; la interpretación es de `CheckpointParser`.
//  El hook de captura y su script solo se instalan cuando el usuario activa la función
//  en un proyecto (`installCheckpointHook`).
//

import Foundation

extension SSHService {
    private static let settingsRelativePath = ".claude/settings.json"

    func runCheckpointCommand(_ command: String) async throws -> CheckpointCommandOutput {
        try RemoteCommandLimit.check(command)
        let result = try await run(command, timeout: .long)
        return CheckpointCommandOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    func checkpointHookInstalled() async throws -> Bool {
        guard CheckpointHookInstaller.isInstalled(in: try await readCheckpointSettings()) else { return false }
        let script = try await readHomeFile(CheckpointScript.installedRelativePath)
        return script == CheckpointScript.source
    }

    /// Sube el script (antes que settings.json: un hook sin script no hace nada) y añade el hook.
    func installCheckpointHook() async throws {
        try await writeHomeFilePrivately(Data(CheckpointScript.source.utf8), to: CheckpointScript.installedRelativePath)
        let merged = CheckpointHookInstaller.installing(into: try await readCheckpointSettings())
        try await writeCheckpointSettings(merged)
    }

    /// Quita el hook de settings.json y borra el script del servidor.
    func uninstallCheckpointHook() async throws {
        let settings = try await readCheckpointSettings()
        if CheckpointHookInstaller.hasAny(in: settings) {
            try await writeCheckpointSettings(CheckpointHookInstaller.removing(from: settings))
        }
        let output = try await runCheckpointCommand(CheckpointCommands.removeScript())
        guard output.stdout.contains("ARGOS_CP_OK") else {
            throw CheckpointError.failed("no se pudo borrar el script de los puntos")
        }
    }

    /// Si el usuario ya activó los puntos en este servidor, deja el hook y el script en
    /// su versión actual. Nunca los añade donde no estaban. Devuelve si escribió.
    @discardableResult
    func upgradeCheckpointHookIfOutdated() async throws -> Bool {
        let settings = try await readCheckpointSettings()
        guard CheckpointHookInstaller.hasAny(in: settings) else { return false }
        let script = try await readHomeFile(CheckpointScript.installedRelativePath)
        let scriptCurrent = script == CheckpointScript.source
        guard !scriptCurrent || !CheckpointHookInstaller.isInstalled(in: settings) else { return false }
        try await installCheckpointHook()
        return true
    }

    private func readCheckpointSettings() async throws -> [String: Any] {
        try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.settingsRelativePath))
    }

    private func writeCheckpointSettings(_ settings: [String: Any]) async throws {
        let content = Data(try ClaudeHookInstaller.serialize(settings).utf8)
        try await writeHomeFilePrivately(content, to: Self.settingsRelativePath, backup: true)
    }
}

extension SSHServicing {
    /// Por defecto (dobles de prueba): no disponible.
    func runCheckpointCommand(_ command: String) async throws -> CheckpointCommandOutput {
        throw CheckpointError.unavailable
    }
    func checkpointHookInstalled() async throws -> Bool { false }
    func installCheckpointHook() async throws { throw CheckpointError.unavailable }
    func uninstallCheckpointHook() async throws { throw CheckpointError.unavailable }
}

extension SessionsViewModel {
    /// Estado de Claude en la sesión del proyecto de `path` (para ofrecer «Ver lo que
    /// cambió en este turno» al terminar y avisar antes de restaurar mientras trabaja).
    func claudeActivity(forProjectPath path: String) -> ClaudeActivity? {
        let sessions = projects.filter { $0.path == path }.map(\.sessionName)
        return claudeActivity.activity(forSessions: sessions)
    }

    /// Interrumpe a Claude (Esc) en los paneles del proyecto donde está trabajando.
    func interruptClaude(forProjectPath path: String) async throws {
        let sessions = Set(projects.filter { $0.path == path }.map(\.sessionName))
        let panes = claudeActivity.panes
            .filter { sessions.contains($0.session) && $0.activity == .working }
            .map(\.paneID)
        guard !panes.isEmpty else { return }
        let output = try await service.runCheckpointCommand(Self.interruptClaudeCommand(panes: panes))
        guard output.exitCode == 0 else {
            throw CheckpointError.failed("no se pudo interrumpir a Claude en tmux")
        }
    }

    nonisolated static func interruptClaudeCommand(panes: [String]) -> String {
        panes.map { "tmux send-keys -t \(ShellQuoting.singleQuoted($0)) Escape" }.joined(separator: " && ")
    }
}
