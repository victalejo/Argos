//
//  RemotePrivateFile.swift
//  Argos
//
//  Lectura/escritura de ficheros de configuración en el $HOME del servidor
//  (`~/.claude/settings.json`, `~/.config/argos/projects.json`, …):
//   - el contenido viaja por SFTP, NUNCA en la línea de comandos (visible en `ps`);
//   - todo se crea bajo `umask 077` (temporal, copia y fichero final en 600);
//   - la escritura es atómica: temporal con nombre único + `mv`, bajo un cerrojo
//     (`<fichero>.argos-lock`, un `mkdir` atómico) compartido por todos los dispositivos;
//   - nunca se escribe A TRAVÉS de un enlace simbólico (temporal y copia se recrean, y
//     un fichero final que sea un enlace no se reemplaza);
//   - opcionalmente, solo se escribe si el fichero sigue siendo el que se leyó
//     (`HomeFileExpectation`): así no se pisa lo que otro dispositivo guardó entretanto.
//

import Foundation

/// Qué debe haber en el fichero justo antes de reemplazarlo.
enum HomeFileExpectation: Equatable, Sendable {
    /// Sin comprobación.
    case any
    /// Inexistente o vacío.
    case absentOrEmpty
    /// Lo que imprime `cksum` del contenido leído (`PosixChecksum.fingerprint`).
    case fingerprint(String)

    init(expected fingerprint: String?) {
        self = fingerprint.map(HomeFileExpectation.fingerprint) ?? .absentOrEmpty
    }
}

enum HomeFileError: LocalizedError, Equatable {
    case locked(String)
    case symlink(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .locked(let path):
            return String(localized: "Otro dispositivo está guardando ~/\(path) en el servidor. Vuelve a intentarlo en unos segundos.")
        case .symlink(let path):
            return String(localized: "~/\(path) es un enlace simbólico y Argos no lo reemplaza. Sustitúyelo por un archivo normal en el servidor.")
        case .unsafePath(let path):
            return String(localized: "Ruta de configuración no válida: \(path).")
        }
    }
}

/// Scripts de escritura (puros, testeables). `relativePath` lo fija el código, nunca el
/// usuario, y solo admite `[A-Za-z0-9._/-]`: se interpola entre comillas dobles para que
/// `$HOME` se expanda.
enum HomeFileScripts {
    static let conflictExitCode = 75
    static let lockedExitCode = 76
    static let symlinkExitCode = 77
    /// Intentos (de 1 s) de tomar el cerrojo; uno de más de un minuto se da por abandonado.
    static let lockAttempts = 10

    static func isSafe(_ relativePath: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-")
        return !relativePath.isEmpty && !relativePath.hasPrefix("/") && !relativePath.contains("..")
            && relativePath.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func temporarySuffix(token: String) -> String { ".argos-tmp-\(token)" }

    /// Paso 1: carpeta y temporal vacío propio (600, sin seguir un enlace previo); imprime `$HOME`.
    static func prepare(_ relativePath: String, token: String) -> String {
        let directory = (relativePath as NSString).deletingLastPathComponent
        let temporary = "\"$HOME/\(relativePath)\(temporarySuffix(token: token))\""
        return "umask 077 && mkdir -p \"$HOME/\(directory)\" && rm -f -- \(temporary) && "
            + "( set -C; : > \(temporary) ) && printf '%s' \"$HOME\""
    }

    /// Paso 3 (sin envolver en `sh -c`): cerrojo, comprobaciones, copia y `mv`.
    static func commit(
        _ relativePath: String, token: String, expectation: HomeFileExpectation, backupSuffix: String?
    ) -> String {
        let name = (relativePath as NSString).lastPathComponent
        var lines = [
            "umask 077",
            "f=\"$HOME/\(relativePath)\"; t=\"$f\(temporarySuffix(token: token))\"; l=\"$f.argos-lock\"",
            "n=0",
            "until mkdir \"$l\" 2>/dev/null; do",
            "  if [ -n \"$(find \"$l\" -maxdepth 0 -mmin +1 2>/dev/null)\" ]; then rmdir \"$l\" 2>/dev/null; continue; fi",
            "  n=$((n + 1)); if [ \"$n\" -ge \(lockAttempts) ]; then rm -f -- \"$t\"; exit \(lockedExitCode); fi",
            "  sleep 1",
            "done",
            "trap 'rmdir \"$l\" 2>/dev/null' EXIT",
            "if [ -L \"$f\" ]; then rm -f -- \"$t\"; exit \(symlinkExitCode); fi",
        ]
        switch expectation {
        case .any:
            break
        case .absentOrEmpty:
            lines.append("[ ! -s \"$f\" ] || { rm -f -- \"$t\"; exit \(conflictExitCode); }")
        case .fingerprint(let value):
            lines.append("set -- $(cksum < \"$f\" 2>/dev/null)")
            lines.append("[ \"$1 $2\" = \(ShellQuoting.singleQuoted(value)) ] || { rm -f -- \"$t\"; exit \(conflictExitCode); }")
        }
        if let backupSuffix {
            lines.append("if [ -f \"$f\" ]; then rm -f -- \"$f\(backupSuffix)\" && cp -- \"$f\" \"$f\(backupSuffix)\" "
                + "|| { rm -f -- \"$t\"; exit 1; }; fi")
        }
        lines.append("mv -f -- \"$t\" \"$f\" || { rm -f -- \"$t\"; exit 1; }")
        // Temporales de escrituras interrumpidas (otro dispositivo, o esta app sin red).
        lines.append("find \"${f%/*}\" -maxdepth 1 -name \(ShellQuoting.singleQuoted(name + ".argos-tmp-*")) "
            + "-mmin +60 -exec rm -f -- {} + 2>/dev/null")
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }
}

extension SSHService {

    /// Contenido de `~/<relativePath>`, o `""` si no existe.
    ///
    /// Un fallo de lectura con el archivo presente (permisos, servidor sin memoria) LANZA:
    /// si se devolviera `""`, quien lee-modifica-escribe guardaría encima solo lo nuevo.
    func readHomeFile(_ relativePath: String) async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.readHomeFileCommand(relativePath))
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: detail.isEmpty ? String(localized: "No se pudo leer ~/\(relativePath).") : detail
            )
        }
        return result.stdout
    }

    /// Sale con 0 y sin salida si el archivo no existe; con el código de `cat` si existe
    /// y no se puede leer (incluido un enlace simbólico roto: el nombre está ocupado).
    static func readHomeFileCommand(_ relativePath: String) -> String {
        let path = "\"$HOME/\(relativePath)\""
        return "[ -e \(path) ] || [ -L \(path) ] || exit 0; cat \(path)"
    }

    /// Escribe `data` en `~/<relativePath>` de forma privada y atómica. Con `backup`,
    /// deja antes una copia en `<fichero>.argos-backup`.
    func writeHomeFilePrivately(_ data: Data, to relativePath: String, backup: Bool = false) async throws {
        _ = try await writeHomeFile(data, to: relativePath, expecting: .any, backupSuffix: backup ? ".argos-backup" : nil)
    }

    /// Escribe `data` solo si el fichero cumple `expectation` (comprobado bajo el cerrojo,
    /// justo antes del `mv`). Devuelve `.conflict` (sin escribir nada) si no la cumple.
    func writeHomeFile(
        _ data: Data, to relativePath: String, expecting expectation: HomeFileExpectation, backupSuffix: String?
    ) async throws -> ProjectsWriteOutcome {
        guard HomeFileScripts.isSafe(relativePath) else { throw HomeFileError.unsafePath(relativePath) }
        let failure = String(localized: "No se pudo escribir ~/\(relativePath).")
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        // 1) Prepara el temporal (600) y resuelve $HOME para la ruta SFTP absoluta.
        let home = try await runChecked(ShellQuoting.posixShell(HomeFileScripts.prepare(relativePath, token: token)), failureMessage: failure)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw SSHServiceError.commandFailed(exitCode: 0, message: String(localized: "No se pudo resolver $HOME en el servidor."))
        }
        let temporary = "\(home)/\(relativePath)\(HomeFileScripts.temporarySuffix(token: token))"
        // 2) Contenido por SFTP sobre el temporal.
        do {
            _ = try await upload(data: data, toRemotePath: temporary)
        } catch {
            _ = try? await runChecked("rm -f -- \(ShellQuoting.singleQuoted(temporary))", failureMessage: failure)
            throw error
        }
        // 3) Cerrojo, comprobación y reemplazo atómico.
        let script = HomeFileScripts.commit(relativePath, token: token, expectation: expectation, backupSuffix: backupSuffix)
        let client = try await connectedClient()
        let result = try await capture(client, command: ShellQuoting.posixShell(script))
        switch result.exitCode {
        case 0: return .written
        case HomeFileScripts.conflictExitCode: return .conflict
        case HomeFileScripts.lockedExitCode: throw HomeFileError.locked(relativePath)
        case HomeFileScripts.symlinkExitCode: throw HomeFileError.symlink(relativePath)
        default:
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(exitCode: result.exitCode, message: message.isEmpty ? failure : message)
        }
    }

    /// Ejecuta un comando y devuelve stdout; lanza `commandFailed` si sale con error.
    func runChecked(_ command: String, failureMessage: String) async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? failureMessage : message
            )
        }
        return result.stdout
    }
}
