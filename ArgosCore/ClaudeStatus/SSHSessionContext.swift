//
//  SSHSessionContext.swift
//  ArgosCore
//
//  Contexto de Argos al arrancar Claude (hook `SessionStart`, ver `SessionContextScript`).
//  - Se activa al instalar el indicador en un servidor que aún no lo tenía, salvo que el
//    usuario lo hubiera apagado (`session-context.off`, que se respeta desde cualquier
//    dispositivo). Donde el indicador ya estaba NO se activa solo: la app lo ofrece.
//  - Al actualizar, solo se pone al día lo que ya estaba activado (script y hook).
//  - settings.json se escribe como los demás hooks (privado, atómico, con copia
//    `.argos-backup`) y además comprobando la huella de lo leído: si otro dispositivo lo
//    cambió entretanto, se relee y se reaplica.
//

import Foundation

extension SSHService {
    private static let contextSettingsPath = ".claude/settings.json"

    func sessionContextStatus() async throws -> SessionContextStatus {
        let flags = try await sessionContextFlags()
        let settings = try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.contextSettingsPath))
        return SessionContextStatus(
            hookInstalled: SessionContextHookInstaller.hasAny(in: settings),
            scriptPresent: flags.scriptPresent,
            turnedOff: flags.turnedOff
        )
    }

    func setSessionContextEnabled(_ enabled: Bool) async throws {
        if enabled {
            // El script antes que settings.json: un hook sin script no hace nada.
            try await uploadSessionContextScript()
            try await updateContextSettings { SessionContextHookInstaller.installing(into: $0) }
            let removed = try await run(SessionContextScript.removeOffMarkerCommand)
            guard removed.exitCode == 0 else {
                throw SSHServiceError.commandFailed(
                    exitCode: Int(removed.exitCode),
                    message: String(localized: "No se pudo borrar ~/.config/argos/session-context.off en el servidor.")
                )
            }
        } else {
            // Primero la marca: aunque falle lo demás, el script ya no dice nada.
            try await writeHomeFilePrivately(Data("1\n".utf8), to: SessionContextScript.offRelativePath)
            try await updateContextSettings { SessionContextHookInstaller.removing(from: $0) }
        }
    }

    func previewSessionContext(projectPath: String) async throws -> SessionContextPreview {
        let result = try await run(SessionContextScript.previewCommand(projectPath: projectPath))
        return SessionContextPreview(output: result.stdout)
    }

    /// Al instalar el indicador en un servidor que no lo tenía: sube el script si el usuario
    /// no apagó el contexto y dice si hay que añadir el hook. Un fallo aquí no impide
    /// instalar el indicador: se registra y sigue sin contexto.
    func prepareSessionContextForNewInstall() async -> Bool {
        do {
            guard try await !sessionContextFlags().turnedOff else { return false }
            try await uploadSessionContextScript()
            return true
        } catch {
            Log.ssh.error("Contexto de Claude al arrancar: \(error.userMessage, privacy: .public)")
            return false
        }
    }

    /// Solo donde ya está activado: deja el script y el hook en su versión actual. Nunca lo
    /// activa. Devuelve si escribió algo.
    @discardableResult
    func upgradeSessionContextIfOutdated() async throws -> Bool {
        let settings = try ClaudeHookInstaller.parseSettings(try await readHomeFile(Self.contextSettingsPath))
        guard SessionContextHookInstaller.hasAny(in: settings), try await !sessionContextFlags().turnedOff else { return false }
        var wrote = false
        if try await readHomeFile(SessionContextScript.installedRelativePath) != SessionContextScript.source {
            try await uploadSessionContextScript()
            wrote = true
        }
        if !SessionContextHookInstaller.isInstalled(in: settings) {
            try await updateContextSettings { SessionContextHookInstaller.installing(into: $0) }
            wrote = true
        }
        return wrote
    }

    // MARK: - Privado

    private func uploadSessionContextScript() async throws {
        try await writeHomeFilePrivately(Data(SessionContextScript.source.utf8), to: SessionContextScript.installedRelativePath)
    }

    private func sessionContextFlags() async throws -> (turnedOff: Bool, scriptPresent: Bool) {
        let output = try await run(SessionContextScript.flagsCommand).stdout
        let words = Set(output.split(whereSeparator: \.isWhitespace).map(String.init))
        return (words.contains("off"), words.contains("script"))
    }

    /// Lee, transforma y escribe settings.json solo si sigue siendo lo leído (huella); si no,
    /// relee y reaplica (como projects.json). Sin cambios no escribe.
    private func updateContextSettings(_ transform: ([String: Any]) -> [String: Any]) async throws {
        for attempt in 1...ProjectsUpdater.maxAttempts {
            let text = try await readHomeFile(Self.contextSettingsPath)
            let settings = try ClaudeHookInstaller.parseSettings(text)
            let updated = transform(settings)
            if NSDictionary(dictionary: updated).isEqual(to: settings) { return }
            let data = Data(try ClaudeHookInstaller.serialize(updated).utf8)
            let expectation = HomeFileExpectation(expected: ProjectsUpdater.expectedFingerprint(of: text))
            switch try await writeHomeFile(data, to: Self.contextSettingsPath, expecting: expectation, backupSuffix: ".argos-backup") {
            case .written:
                return
            case .conflict:
                Log.ssh.notice("settings.json cambió mientras se guardaba (intento \(attempt)); se relee.")
            }
        }
        throw SSHServiceError.commandFailed(
            exitCode: Int(HomeFileScripts.conflictExitCode),
            message: String(localized: "~/.claude/settings.json está cambiando a la vez desde otro sitio. Vuelve a intentarlo en unos segundos.")
        )
    }
}

extension SSHServicing {
    /// Por defecto (dobles de prueba): nunca activado.
    func sessionContextStatus() async throws -> SessionContextStatus {
        SessionContextStatus(hookInstalled: false, scriptPresent: false, turnedOff: false)
    }
    func setSessionContextEnabled(_ enabled: Bool) async throws {
        throw SSHService.SSHServiceError.commandFailed(exitCode: 1, message: String(localized: "No disponible en este servidor."))
    }
    func previewSessionContext(projectPath: String) async throws -> SessionContextPreview {
        SessionContextPreview(output: "")
    }
}
