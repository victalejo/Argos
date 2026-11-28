//
//  SSHSessionContext.swift
//  ArgosCore
//
//  Contexto de Argos al arrancar Claude (hook `SessionStart`, ver `SessionContextScript`).
//  Se activa por defecto al instalar o actualizar los hooks del indicador, salvo que el
//  usuario lo haya apagado en ese servidor (`session-context.off`, que se respeta también
//  desde otros dispositivos). settings.json se escribe como los demás hooks: privado,
//  atómico y con copia `.argos-backup`.
//

import Foundation

extension SSHService {
    private static let contextSettingsPath = ".claude/settings.json"

    func sessionContextEnabled() async throws -> Bool {
        guard try await !sessionContextIsOff() else { return false }
        return SessionContextHookInstaller.hasAny(in: try await readContextSettings())
    }

    func setSessionContextEnabled(_ enabled: Bool) async throws {
        let settings = try await readContextSettings()
        if enabled {
            // El script antes que settings.json: un hook sin script no hace nada.
            try await writeHomeFilePrivately(Data(SessionContextScript.source.utf8), to: SessionContextScript.installedRelativePath)
            try await writeContextSettings(SessionContextHookInstaller.installing(into: settings))
            _ = try await run(Self.removeOffMarkerCommand)
        } else {
            // Primero la marca: aunque falle lo demás, el script ya no dice nada.
            try await writeHomeFilePrivately(Data("1\n".utf8), to: SessionContextScript.offRelativePath)
            if SessionContextHookInstaller.hasAny(in: settings) {
                try await writeContextSettings(SessionContextHookInstaller.removing(from: settings))
            }
        }
    }

    func previewSessionContext(projectPath: String) async throws -> SessionContextPreview {
        let result = try await run(SessionContextScript.previewCommand(projectPath: projectPath))
        return SessionContextPreview(output: result.stdout)
    }

    /// `settings` con el hook de contexto añadido (y el script subido) salvo que el usuario
    /// lo apagara. Un fallo aquí no impide instalar el indicador: se registra y sigue.
    func addingSessionContextByDefault(to settings: [String: Any]) async -> [String: Any] {
        do {
            guard try await !sessionContextIsOff() else { return settings }
            if try await readHomeFile(SessionContextScript.installedRelativePath) != SessionContextScript.source {
                try await writeHomeFilePrivately(Data(SessionContextScript.source.utf8), to: SessionContextScript.installedRelativePath)
            }
            return SessionContextHookInstaller.installing(into: settings)
        } catch {
            Log.ssh.error("Contexto de Claude al arrancar: \(error.userMessage, privacy: .public)")
            return settings
        }
    }

    /// Si el indicador (o el propio contexto) ya está en este servidor y nadie lo apagó,
    /// deja el hook y el script en su versión actual. Devuelve si escribió settings.json.
    @discardableResult
    func upgradeSessionContextIfOutdated() async throws -> Bool {
        let settings = try await readContextSettings()
        guard ClaudeHookInstaller.hasAnyOurs(in: settings) || SessionContextHookInstaller.hasAny(in: settings) else { return false }
        let merged = await addingSessionContextByDefault(to: settings)
        guard SessionContextHookInstaller.isInstalled(in: merged), !SessionContextHookInstaller.isInstalled(in: settings) else {
            return false
        }
        try await writeContextSettings(merged)
        return true
    }

    private static var offMarker: String { "\"$HOME/\(SessionContextScript.offRelativePath)\"" }
    private static var removeOffMarkerCommand: String { "rm -f \(offMarker)" }
    /// Como el script: apagado si la marca existe (sea cual sea su contenido).
    static var offMarkerCheckCommand: String { "[ -e \(offMarker) ] && echo off; exit 0" }

    private func sessionContextIsOff() async throws -> Bool {
        try await run(Self.offMarkerCheckCommand).stdout.contains("off")
    }

    private func readContextSettings() async throws -> [String: Any] {
        try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.contextSettingsPath))
    }

    private func writeContextSettings(_ settings: [String: Any]) async throws {
        let content = Data(try ClaudeHookInstaller.serialize(settings).utf8)
        try await writeHomeFilePrivately(content, to: Self.contextSettingsPath, backup: true)
    }
}

extension SSHServicing {
    /// Por defecto (dobles de prueba): no disponible.
    func sessionContextEnabled() async throws -> Bool { false }
    func setSessionContextEnabled(_ enabled: Bool) async throws {
        throw SSHService.SSHServiceError.commandFailed(exitCode: 1, message: String(localized: "No disponible en este servidor."))
    }
    func previewSessionContext(projectPath: String) async throws -> SessionContextPreview {
        SessionContextPreview(output: "")
    }
}
