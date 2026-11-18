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
    /// La primera subida de cada conexión limpia, de paso, las antiguas de `/tmp`.
    func uploadPrivately(data: Data, toRemotePath remotePath: String) async throws -> String {
        await cleanStaleUploadsOnce()
        var attributes = SFTPFileAttributes()
        attributes.permissions = RemoteUpload.privatePermissions
        return try await write(
            data,
            to: remotePath,
            flags: SFTPOpenFileFlags(rawValue: RemoteUpload.exclusiveOpenFlags),
            attributes: attributes
        )
    }

    /// Borra (una vez por conexión) las subidas de este usuario con más de
    /// `RemoteUpload.retentionDays` días. Un fallo solo se registra.
    private func cleanStaleUploadsOnce() async {
        guard await RemoteUploadCleanup.shared.claim(ObjectIdentifier(self)) else { return }
        do {
            _ = try await runChecked(RemoteUpload.staleCleanupCommand, failureMessage: String(localized: "No se pudo limpiar /tmp."))
        } catch {
            Log.ssh.notice("Limpieza de subidas antiguas en /tmp: \(error.userMessage, privacy: .public)")
        }
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
        do {
            // La conexión se resuelve dentro del turno (la de antes de esperar pudo caerse).
            try await withSharedChannel { client in
                try await client.withSFTP { sftp in
                    try await sftp.withFile(
                        filePath: remotePath,
                        flags: flags,
                        attributes: attributes
                    ) { file in
                        try await file.write(ByteBuffer(bytes: data))
                    }
                }
            }
        } catch {
            let message = error.userMessage
            throw SSHServiceError.uploadFailed(message)
        }
        Log.ssh.notice("Archivo subido por SFTP a \(remotePath, privacy: .public) (\(data.count, privacy: .public) bytes)")
        return remotePath
    }
}

/// Conexiones que ya limpiaron `/tmp` (una vez por servicio y ejecución de la app).
actor RemoteUploadCleanup {
    static let shared = RemoteUploadCleanup()
    private var done: Set<ObjectIdentifier> = []

    /// `true` la primera vez para `id`.
    func claim(_ id: ObjectIdentifier) -> Bool { done.insert(id).inserted }
}
