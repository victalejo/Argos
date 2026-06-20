//
//  SSHFileTransfer.swift
//  Argos
//
//  Transferencia de archivos vía SFTP (subsistema sftp sobre la misma conexión SSH).
//  Uso principal: subir una imagen del portapapeles del Mac al servidor para que una
//  app remota (p. ej. Claude Code) pueda leerla por ruta.
//

import Foundation
@preconcurrency import Citadel
import NIOCore

extension SSHService {

    /// Sube datos crudos a `/tmp/argos-pasted-<timestamp>.<ext>` en el servidor y
    /// devuelve la ruta remota absoluta. Se usa `/tmp` por ser siempre escribible y
    /// de ruta absoluta conocida (no depende de resolver `$HOME`).
    ///
    /// - Parameters:
    ///   - data: bytes del archivo (p. ej. PNG de un screenshot).
    ///   - fileExtension: extensión sin punto (p. ej. "png").
    /// - Returns: ruta remota absoluta del archivo subido.
    func uploadPastedFile(data: Data, fileExtension: String) async throws -> String {
        try await upload(data: data, toRemotePath: "/tmp/argos-pasted-\(Self.stamp()).\(fileExtension)")
    }

    /// Sube un archivo arrastrado desde Finder, conservando su nombre (saneado) bajo
    /// `/tmp/argos-<timestamp>-<nombre>`. Devuelve la ruta remota absoluta.
    func uploadDroppedFile(data: Data, originalName: String) async throws -> String {
        let safeName = Self.sanitize(originalName)
        return try await upload(data: data, toRemotePath: "/tmp/argos-\(Self.stamp())-\(safeName)")
    }

    /// Escribe `data` en `remotePath` vía SFTP (crea/trunca). Lanza `uploadFailed`.
    private func upload(data: Data, toRemotePath remotePath: String) async throws -> String {
        let client = try await connectedClient()
        do {
            try await client.withSFTP { sftp in
                try await sftp.withFile(
                    filePath: remotePath,
                    flags: [.write, .create, .truncate]
                ) { file in
                    try await file.write(ByteBuffer(bytes: data))
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw SSHServiceError.uploadFailed(message)
        }
        Log.ssh.notice("Archivo subido por SFTP a \(remotePath, privacy: .public) (\(data.count, privacy: .public) bytes)")
        return remotePath
    }

    private static func stamp() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Sanea un nombre de archivo: deja solo `[A-Za-z0-9._-]`, el resto → `_`. Evita
    /// rutas, espacios y caracteres que romperían la ruta al insertarla en el terminal.
    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let scalars = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "archivo" : result
    }
}
