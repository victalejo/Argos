//
//  SSHTerminalTools.swift
//  ArgosCore
//
//  Canal de comandos de las herramientas del terminal (búsqueda en el historial, copiar
//  la última salida) y la instalación de las marcas de prompt OSC 133 en el servidor.
//

import Foundation

enum ShellIntegrationError: LocalizedError, Equatable {
    case unsupportedShell(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShell(let shell):
            return String(localized: "Las marcas de prompt solo están disponibles para zsh y bash (el shell del servidor es «\(shell)»).")
        }
    }
}

extension SSHService {

    /// Plazo en el servidor de los comandos del terminal (búsqueda, capturas).
    static let terminalToolSeconds = 30

    /// Ejecuta `script` (sh POSIX) con plazo y devuelve stdout; lanza si sale con error.
    func runTerminalCommand(_ script: String) async throws -> String {
        let result = try await run(
            RemoteTimeout.wrap(script, seconds: Self.terminalToolSeconds),
            timeout: .custom(.seconds(Self.terminalToolSeconds + 10))
        )
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: detail.isEmpty ? String(localized: "tmux no pudo completar la orden.") : String(detail.suffix(400))
            )
        }
        return result.stdout
    }

    func shellIntegrationStatus() async throws -> ShellIntegrationStatus {
        var anyBlock = false
        for shell in ShellIntegrationBlock.Shell.allCases {
            let content = try await readHomeFile(shell.rcFile)
            if ShellIntegrationBlock.isCurrent(in: content, shell: shell) { return .installed }
            anyBlock = anyBlock || ShellIntegrationBlock.isInstalled(in: content)
        }
        return anyBlock ? .outdated : .notInstalled
    }

    /// Añade (o pone al día) el bloque en los rc de zsh/bash que existan y en el del shell
    /// de inicio de sesión. Deja copia de cada archivo en `<archivo>.argos-backup`.
    func installShellIntegration() async throws {
        let shells = try await shellIntegrationTargets()
        for shell in shells {
            let content = try await readHomeFile(shell.rcFile)
            let updated = ShellIntegrationBlock.installing(into: content, shell: shell)
            guard updated != content else { continue }
            try await writeHomeFilePrivately(Data(updated.utf8), to: shell.rcFile, backup: true)
        }
    }

    /// Quita el bloque de los rc donde esté (con copia); el resto del archivo no cambia.
    func removeShellIntegration() async throws {
        for shell in ShellIntegrationBlock.Shell.allCases {
            let content = try await readHomeFile(shell.rcFile)
            guard ShellIntegrationBlock.isInstalled(in: content) else { continue }
            try await writeHomeFilePrivately(Data(ShellIntegrationBlock.removing(from: content).utf8), to: shell.rcFile, backup: true)
        }
    }

    /// Los rc que existen y el del shell de inicio de sesión.
    private func shellIntegrationTargets() async throws -> [ShellIntegrationBlock.Shell] {
        let output = try await runChecked(
            ShellQuoting.posixShell(Self.shellIntegrationProbe),
            failureMessage: String(localized: "No se pudo leer el shell del servidor.")
        )
        return try Self.shellIntegrationTargets(probeOutput: output)
    }

    static let shellIntegrationProbe =
        "printf 'shell %s\\n' \"${SHELL-}\"; for f in .zshrc .bashrc; do [ -e \"$HOME/$f\" ] && printf 'rc %s\\n' \"$f\"; done; exit 0"

    /// Lógica pura de `shellIntegrationTargets`.
    static func shellIntegrationTargets(probeOutput: String) throws -> [ShellIntegrationBlock.Shell] {
        var login = ""
        var existing: Set<String> = []
        for line in probeOutput.split(separator: "\n").map(String.init) {
            if line.hasPrefix("shell ") { login = String(line.dropFirst(6)) }
            if line.hasPrefix("rc ") { existing.insert(String(line.dropFirst(3))) }
        }
        let loginShell = ShellIntegrationBlock.Shell(loginShell: login)
        let shells = ShellIntegrationBlock.Shell.allCases.filter { existing.contains($0.rcFile) || $0 == loginShell }
        guard !shells.isEmpty else {
            throw ShellIntegrationError.unsupportedShell((login as NSString).lastPathComponent)
        }
        return shells
    }
}

extension SSHServicing {
    /// Por defecto (dobles de prueba): no disponible.
    func runTerminalCommand(_ script: String) async throws -> String {
        throw SSHService.SSHServiceError.commandFailed(exitCode: -1, message: String(localized: "Función no disponible."))
    }
    func shellIntegrationStatus() async throws -> ShellIntegrationStatus { .notInstalled }
    func installShellIntegration() async throws {}
    func removeShellIntegration() async throws {}
}
