//
//  SSHTerminalTools.swift
//  ArgosCore
//
//  Canal de comandos de las herramientas del terminal (búsqueda en el historial, copiar
//  la última salida) y la instalación de las marcas de prompt OSC 133 en el servidor.
//
//  Los rc se leen con `ShellRcProbe` (base64 entre marcas: ni ruido del arranque ni bytes
//  alterados), se escriben solo si siguen siendo los que se leyeron (huella `cksum`, bajo
//  el cerrojo de `writeHomeFile`, con copia `.argos-backup`) y conservan sus permisos. Un
//  enlace (simbólico o duro) o un archivo que no es UTF-8 no se reescribe.
//

import Foundation

enum ShellIntegrationError: LocalizedError, Equatable {
    case unsupportedShell(String)
    case notRegularFile(String)
    case notUTF8(String)
    case changed(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupportedShell(let shell):
            return String(localized: "Las marcas de prompt solo están disponibles para zsh y bash (el shell del servidor es «\(shell)»).")
        case .notRegularFile(let file):
            return String(localized: "~/\(file) es un enlace o no es un archivo normal: Argos no lo modifica. Añade el bloque a mano o sustitúyelo por un archivo.")
        case .notUTF8(let file):
            return String(localized: "~/\(file) no es texto UTF-8: Argos no lo modifica para no estropearlo.")
        case .changed(let file):
            return String(localized: "~/\(file) cambió mientras Argos lo editaba. Vuelve a intentarlo.")
        case .unreadable:
            return String(localized: "No se pudo leer el shell del servidor.")
        }
    }
}

/// Estado de las marcas de prompt y, si las hay, la razón por la que no se cargarían.
struct ShellIntegrationReport: Equatable, Sendable {
    let status: ShellIntegrationStatus
    let warning: String?
}

/// Una escritura de rc que hay que hacer (lógica pura).
struct ShellRcEdit: Equatable, Sendable {
    let shell: ShellIntegrationBlock.Shell
    let content: Data
    let expectation: HomeFileExpectation
    /// Permisos que tenía (se restauran tras escribir).
    let mode: String?

    /// Qué escribir para instalar (`enable`) o quitar el bloque.
    static func plan(_ report: ShellRcProbe.Report, enable: Bool) throws -> [ShellRcEdit] {
        guard report.complete else { throw ShellIntegrationError.unreadable }
        let shells: [ShellIntegrationBlock.Shell]
        if enable {
            shells = try ShellRcProbe.targets(report)
        } else {
            shells = ShellIntegrationBlock.Shell.allCases.filter { shell in
                guard case .file(let data, _) = report.files[shell] else { return false }
                return ShellIntegrationBlock.isInstalled(in: String(decoding: data, as: UTF8.self))
            }
        }
        return try shells.compactMap { shell in
            let state = report.files[shell]
            let text = try ShellRcProbe.text(of: state, shell: shell)
            let updated = enable ? ShellIntegrationBlock.installing(into: text, shell: shell) : ShellIntegrationBlock.removing(from: text)
            guard updated != text else { return nil }
            let expectation: HomeFileExpectation
            var mode: String?
            if case .file(let data, let fileMode) = state {
                expectation = .fingerprint(PosixChecksum.fingerprint(of: data))
                mode = fileMode
            } else {
                expectation = .absentOrEmpty
            }
            return ShellRcEdit(shell: shell, content: Data(updated.utf8), expectation: expectation, mode: mode)
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

    func shellIntegrationStatus() async throws -> ShellIntegrationReport {
        let report = try await probeShellRc()
        return ShellIntegrationReport(status: ShellRcProbe.status(report), warning: ShellRcProbe.warning(report))
    }

    /// Añade (o pone al día) el bloque en los rc de zsh/bash que existan y en el del shell
    /// de inicio de sesión.
    func installShellIntegration() async throws {
        try await apply(ShellRcEdit.plan(try await probeShellRc(), enable: true))
    }

    /// Quita el bloque de los rc donde esté; el resto del archivo no cambia.
    func removeShellIntegration() async throws {
        try await apply(ShellRcEdit.plan(try await probeShellRc(), enable: false))
    }

    private func probeShellRc() async throws -> ShellRcProbe.Report {
        let nonce = TerminalSearchCommands.nonce()
        let output = try await runChecked(
            ShellQuoting.posixShell(ShellRcProbe.command(nonce: nonce)),
            failureMessage: String(localized: "No se pudo leer el shell del servidor.")
        )
        return ShellRcProbe.parse(output, nonce: nonce)
    }

    private func apply(_ edits: [ShellRcEdit]) async throws {
        for edit in edits {
            let file = edit.shell.rcFile
            let outcome = try await writeHomeFile(edit.content, to: file, expecting: edit.expectation, backupSuffix: ".argos-backup")
            guard outcome == .written else { throw ShellIntegrationError.changed(file) }
            if let mode = edit.mode {
                // La escritura privada lo deja en 600: vuelve a sus permisos de antes.
                _ = try? await runChecked("chmod \(mode) \"$HOME/\(file)\"", failureMessage: "")
            }
        }
    }
}

extension SSHServicing {
    /// Por defecto (dobles de prueba): no disponible.
    func runTerminalCommand(_ script: String) async throws -> String {
        throw SSHService.SSHServiceError.commandFailed(exitCode: -1, message: String(localized: "Función no disponible."))
    }
    func shellIntegrationStatus() async throws -> ShellIntegrationReport {
        ShellIntegrationReport(status: .notInstalled, warning: nil)
    }
    func installShellIntegration() async throws {}
    func removeShellIntegration() async throws {}
}
