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

    /// Sube datos crudos a una ruta privada de `/tmp` (ver `RemoteUpload`) y devuelve la
    /// ruta remota absoluta. Se usa `/tmp` por ser siempre escribible y de ruta absoluta
    /// conocida (no depende de resolver `$HOME`).
    ///
    /// - Parameters:
    ///   - data: bytes del archivo (p. ej. PNG de un screenshot).
    ///   - fileExtension: extensión sin punto (p. ej. "png").
    /// - Returns: ruta remota absoluta del archivo subido.
    func uploadPastedFile(data: Data, fileExtension: String) async throws -> String {
        try await uploadPrivately(data: data, toRemotePath: RemoteUpload.pastedPath(fileExtension: fileExtension))
    }

    /// Sube un archivo arrastrado desde Finder a una ruta privada de `/tmp`, conservando
    /// su nombre (saneado). Devuelve la ruta remota absoluta.
    func uploadDroppedFile(data: Data, originalName: String) async throws -> String {
        try await uploadPrivately(data: data, toRemotePath: RemoteUpload.droppedPath(originalName: originalName))
    }

    /// Crea `remotePath` en exclusiva y con permisos 0600. Falla si la ruta ya existe.
    private func uploadPrivately(data: Data, toRemotePath remotePath: String) async throws -> String {
        var attributes = SFTPFileAttributes()
        attributes.permissions = RemoteUpload.privatePermissions
        return try await write(
            data,
            to: remotePath,
            flags: SFTPOpenFileFlags(rawValue: RemoteUpload.exclusiveOpenFlags),
            attributes: attributes
        )
    }

    /// Escribe `data` en `remotePath` vía SFTP (crea/trunca). Lanza `uploadFailed`. Solo
    /// para rutas del usuario: en `/tmp` hay que usar `uploadPrivately`.
    /// El contenido viaja por el canal SFTP, nunca por la línea de comandos (no queda
    /// expuesto en `ps` a otros usuarios del servidor).
    func upload(data: Data, toRemotePath remotePath: String) async throws -> String {
        try await write(data, to: remotePath, flags: [.write, .create, .truncate], attributes: .none)
    }

    private func write(
        _ data: Data,
        to remotePath: String,
        flags: SFTPOpenFileFlags,
        attributes: SFTPFileAttributes
    ) async throws -> String {
        let client = try await connectedClient()
        do {
            try await client.withSFTP { sftp in
                try await sftp.withFile(
                    filePath: remotePath,
                    flags: flags,
                    attributes: attributes
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
}
