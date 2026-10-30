//
//  SSHProjectSync.swift
//  Argos
//
//  Transferencia de proyectos entre el servidor y el Mac por la conexión SSH existente
//  (SFTP + un `find` para listar). Sin rsync/ssh locales: la app está en sandbox.
//  Toda ruta relativa se valida (`SyncPath`) y se resuelve dentro de la raíz.
//

import Foundation
@preconcurrency import Citadel
import NIOCore

extension SSHService {

    /// Archivos del proyecto en el servidor (sin carpetas excluidas).
    func syncFileList(root: String) async throws -> [SyncFile] {
        let client = try await connectedClient()
        let result = try await capture(client, command: ServerFileList.command(root: root))
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? "No se pudo listar la carpeta del proyecto." : message
            )
        }
        return ServerFileList.parse(result.stdout)
    }

    /// Descarga `file` a `localURL` (escritura por bloques; no carga archivos grandes enteros
    /// en memoria). Los enlaces simbólicos los crea el llamador.
    func downloadSyncFile(root: String, file: SyncFile, to localURL: URL) async throws {
        guard SyncPath.isSafeRelative(file.path) else { throw FileBrowserError.outsideProject(file.path) }
        let sftp = try await browserSFTPClient()
        let remote = RemotePath.join(root, file.path)

        let temporary = localURL.appendingPathExtension("argos-down")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try await sftp.withFile(filePath: remote, flags: .read) { remoteFile in
                var offset: UInt64 = 0
                while true {
                    let chunk = try await remoteFile.read(from: offset, length: 256 * 1024)
                    guard chunk.readableBytes > 0 else { break }
                    try handle.write(contentsOf: Data(chunk.readableBytesView))
                    offset += UInt64(chunk.readableBytes)
                }
            }
            try handle.close()
            _ = try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: temporary, to: localURL)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Crea en el servidor las carpetas (relativas a `root`) que hacen falta para subir.
    func makeRemoteDirectories(root: String, relativeDirectories: [String]) async throws {
        let safe = relativeDirectories.filter(SyncPath.isSafeRelative)
        guard !safe.isEmpty else { return }
        let client = try await connectedClient()
        // En lotes para no exceder la longitud máxima de la línea de comandos.
        for batch in stride(from: 0, to: safe.count, by: 200).map({ Array(safe[$0..<min($0 + 200, safe.count)]) }) {
            let paths = batch.map { ShellQuoting.singleQuoted($0) }.joined(separator: " ")
            let result = try await capture(client, command: "cd \(ShellQuoting.singleQuoted(root)) && mkdir -p -- \(paths)")
            guard result.exitCode == 0 else {
                throw SSHServiceError.commandFailed(exitCode: result.exitCode, message: result.stderr)
            }
        }
    }

    /// Sube un archivo del Mac: a un temporal y luego lo coloca en su sitio; fija
    /// permisos y fecha para que coincida con la copia local.
    func uploadSyncFile(root: String, file: SyncFile, from localURL: URL) async throws {
        guard SyncPath.isSafeRelative(file.path) else { throw FileBrowserError.outsideProject(file.path) }
        let sftp = try await browserSFTPClient()
        let remote = RemotePath.join(root, file.path)

        if let target = file.linkTarget {
            let client = try await connectedClient()
            let command = "ln -sfn -- \(ShellQuoting.singleQuoted(target)) \(ShellQuoting.singleQuoted(remote))"
            let result = try await capture(client, command: command)
            guard result.exitCode == 0 else { throw SSHServiceError.commandFailed(exitCode: result.exitCode, message: result.stderr) }
            return
        }

        let temporary = remote + ".argos-up"
        let reader = try FileHandle(forReadingFrom: localURL)
        defer { try? reader.close() }
        try await sftp.withFile(filePath: temporary, flags: [.write, .create, .truncate]) { remoteFile in
            var offset: UInt64 = 0
            while let data = try reader.read(upToCount: 256 * 1024), !data.isEmpty {
                try await remoteFile.write(ByteBuffer(bytes: data), at: offset)
                offset += UInt64(data.count)
            }
        }
        // SFTP v3 no renombra sobre un archivo existente: se borra antes el destino.
        try? await sftp.remove(at: remote)
        try await sftp.rename(at: temporary, to: remote)

        var attributes = SFTPFileAttributes()
        attributes.permissions = UInt32(file.mode)
        let date = Date(timeIntervalSince1970: TimeInterval(file.mtime))
        attributes.accessModificationTime = .init(accessTime: date, modificationTime: date)
        try await sftp.setAttributes(at: remote, to: attributes)
    }

    func deleteRemoteSyncFile(root: String, relativePath: String) async throws {
        guard SyncPath.isSafeRelative(relativePath) else { throw FileBrowserError.outsideProject(relativePath) }
        let sftp = try await browserSFTPClient()
        try await sftp.remove(at: RemotePath.join(root, relativePath))
    }
}
