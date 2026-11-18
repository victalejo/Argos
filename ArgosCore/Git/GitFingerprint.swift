//
//  GitFingerprint.swift
//  ArgosCore
//
//  Huella barata de un cambio (lógica pura): el `cksum` de su diff, calculado EN EL
//  SERVIDOR (solo viajan unos bytes). Si la huella cambia, el diff que se ve está viejo.
//  El panel «Cambios» la consulta en cada sondeo para el archivo seleccionado y antes de
//  un commit para los archivos ya revisados.
//

import Foundation

enum GitFingerprint {
    static let marker = "ARGOS_FP:"

    private static func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }

    /// Fragmento que imprime `ARGOS_FP:<crc> <bytes>` para un cambio. Un archivo sin
    /// seguimiento se resume por su contenido; uno seguido, por su diff frente a `HEAD`
    /// (o índice + árbol sin commits). Siempre imprime una línea, aunque falle.
    static func line(root: String, change: GitFileChange, hasCommits: Bool) -> String {
        let git = GitCommands.git(root)
        let diff = "\(git) diff --no-color --no-ext-diff --binary"
        let paths = change.affectedPaths.map(q).joined(separator: " ")
        let body: String
        if change.isUntracked {
            body = "cat -- \(q(RemotePath.join(root, change.path)))"
        } else if hasCommits {
            body = "\(diff) HEAD -- \(paths)"
        } else {
            body = "\(diff) --cached -- \(paths); \(diff) -- \(paths)"
        }
        return "printf '%s' '\(marker)'; { \(body); } 2>/dev/null | cksum"
    }

    /// Comandos (en lotes que caben en un argumento) para `changes`, en orden.
    static func commands(root: String, changes: [GitFileChange], hasCommits: Bool) -> [String] {
        let lines = changes.map { line(root: root, change: $0, hasCommits: hasCommits) }
        return RemoteCommandLimit.batches(lines).map { ShellQuoting.posixShell($0.joined(separator: "\n")) }
    }

    /// Huellas en orden a partir de la salida (ignora el ruido del perfil del shell).
    static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: marker) else { return nil }
            return line[range.upperBound...].split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
        }
    }
}

extension SSHService {
    func gitFingerprints(root: String, changes: [GitFileChange], hasCommits: Bool) async throws -> [String] {
        guard !changes.isEmpty else { return [] }
        let client = try await connectedClient()
        var result: [String] = []
        for command in GitFingerprint.commands(root: root, changes: changes, hasCommits: hasCommits) {
            try RemoteCommandLimit.check(command)
            result += GitFingerprint.parse(try await capture(client, command: command).stdout)
        }
        guard result.count == changes.count else {
            throw GitCommandError(message: "No se pudo comprobar si los archivos cambiaron en el servidor.")
        }
        return result
    }
}
