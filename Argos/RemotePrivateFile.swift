//
//  RemotePrivateFile.swift
//  Argos
//
//  Lectura/escritura de ficheros de configuración en el $HOME del servidor
//  (`~/.claude/settings.json`, `~/.config/argos/projects.json`, …):
//   - el contenido viaja por SFTP, NUNCA en la línea de comandos (visible en `ps`);
//   - todo se crea bajo `umask 077` (temporal, copia y fichero final en 600);
//   - la escritura es atómica: temporal + `mv`.
//

import Foundation

extension SSHService {

    /// Contenido de `~/<relativePath>`, o `""` si no existe.
    func readHomeFile(_ relativePath: String) async throws -> String {
        let client = try await connectedClient()
        let result = try await capture(client, command: "cat \"$HOME/\(relativePath)\" 2>/dev/null")
        return result.exitCode == 0 ? result.stdout : ""
    }

    /// Escribe `data` en `~/<relativePath>` de forma privada y atómica. Con `backup`,
    /// deja antes una copia en `<fichero>.argos-backup`.
    ///
    /// `relativePath` lo fija siempre el código (no el usuario): se interpola entre
    /// comillas dobles para que `$HOME` se expanda.
    func writeHomeFilePrivately(_ data: Data, to relativePath: String, backup: Bool = false) async throws {
        let path = "$HOME/\(relativePath)"
        let directory = (relativePath as NSString).deletingLastPathComponent
        var steps = ["umask 077", "mkdir -p \"$HOME/\(directory)\""]
        if backup {
            steps.append("{ [ ! -f \"\(path)\" ] || cp \"\(path)\" \"\(path).argos-backup\"; }")
        }
        steps += [": > \"\(path).argos-tmp\"", "printf '%s' \"$HOME\""]

        // 1) Prepara el temporal (600) y resuelve $HOME para la ruta SFTP absoluta.
        let home = try await runChecked(steps.joined(separator: " && "), failureMessage: "No se pudo escribir ~/\(relativePath).")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else {
            throw SSHServiceError.commandFailed(exitCode: 0, message: "No se pudo resolver $HOME en el servidor.")
        }
        // 2) Contenido por SFTP sobre el temporal.
        _ = try await upload(data: data, toRemotePath: "\(home)/\(relativePath).argos-tmp")
        // 3) Reemplazo atómico.
        _ = try await runChecked(
            "mv \"\(path).argos-tmp\" \"\(path)\"",
            failureMessage: "No se pudo escribir ~/\(relativePath)."
        )
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
