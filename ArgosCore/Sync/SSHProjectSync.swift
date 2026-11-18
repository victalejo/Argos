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
        let result = try await capture(client, command: ServerFileList.command(root: root), timeout: .long)
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
        let safe = relativeDirectories.filter(SyncPath.isSafeRelative).map(ShellQuoting.singleQuoted)
        guard !safe.isEmpty else { return }
        // En lotes (por bytes) para no exceder la longitud máxima de un argumento.
        for batch in RemoteCommandLimit.batches(safe) {
            let command = "cd \(ShellQuoting.singleQuoted(root)) && mkdir -p -- \(batch.joined(separator: " "))"
            try await runSyncCommand(command, failureMessage: "No se pudieron crear las carpetas en el servidor.")
        }
    }

    /// Sube un archivo del Mac y lo coloca en su sitio (atómico: ver `SyncStaging`).
    func uploadSyncFile(root: String, file: SyncFile, from localURL: URL) async throws {
        try await stageSyncFile(root: root, file: file, from: localURL)
        do {
            try await placeStagedSyncFiles(root: root, files: [file])
        } catch {
            await discardStagedQuietly(root: root, paths: [file.path])
            throw error
        }
    }

    /// Sube el archivo a `<ruta>.argos-up` con los permisos y la fecha de la copia local
    /// (`mv` los conserva al colocarlo). Los enlaces no se suben: se crean al colocar.
    /// Si falla, borra su temporal.
    func stageSyncFile(root: String, file: SyncFile, from localURL: URL) async throws {
        guard SyncPath.isSafeRelative(file.path) else { throw FileBrowserError.outsideProject(file.path) }
        guard file.linkTarget == nil else { return }
        let sftp = try await browserSFTPClient()
        let temporary = SyncStaging.temporaryPath(for: RemotePath.join(root, file.path))
        do {
            let reader = try FileHandle(forReadingFrom: localURL)
            defer { try? reader.close() }
            try await sftp.withFile(filePath: temporary, flags: [.write, .create, .truncate]) { remoteFile in
                var offset: UInt64 = 0
                while let data = try reader.read(upToCount: 256 * 1024), !data.isEmpty {
                    try await remoteFile.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                }
            }
            var attributes = SFTPFileAttributes()
            attributes.permissions = UInt32(file.mode)
            let date = Date(timeIntervalSince1970: TimeInterval(file.mtime))
            attributes.accessModificationTime = .init(accessTime: date, modificationTime: date)
            try await sftp.setAttributes(at: temporary, to: attributes)
        } catch {
            do {
                try await sftp.remove(at: temporary)
            } catch let cleanup {
                Log.ssh.error("No se pudo borrar el temporal \(temporary, privacy: .public): \(String(describing: cleanup), privacy: .public)")
            }
            throw error
        }
    }

    /// Coloca los temporales de `files` (y crea sus enlaces) con `mv -f`, por lotes.
    func placeStagedSyncFiles(root: String, files: [SyncFile]) async throws {
        for command in SyncStaging.placeCommands(root: root, files: files) {
            try await runSyncCommand(command, failureMessage: "No se pudieron colocar los archivos subidos.")
        }
    }

    /// Borra los temporales de `paths` (camino de error).
    func discardStagedSyncFiles(root: String, paths: [String]) async throws {
        for command in SyncStaging.discardCommands(root: root, paths: paths) {
            try await runSyncCommand(command, failureMessage: "No se pudieron borrar los temporales de la subida.")
        }
    }

    /// Borra los temporales huérfanos de envíos anteriores interrumpidos.
    func removeStaleSyncTemporaries(root: String) async throws {
        try await runSyncCommand(
            SyncStaging.staleCleanupCommand(root: root),
            failureMessage: "No se pudieron limpiar los temporales de envíos anteriores."
        )
    }

    private func discardStagedQuietly(root: String, paths: [String]) async {
        do {
            try await discardStagedSyncFiles(root: root, paths: paths)
        } catch {
            Log.ssh.error("Temporales de subida sin borrar: \(String(describing: error), privacy: .public)")
        }
    }

    private func runSyncCommand(_ command: String, failureMessage: String) async throws {
        try RemoteCommandLimit.check(command)
        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? failureMessage : message
            )
        }
    }

    func deleteRemoteSyncFile(root: String, relativePath: String) async throws {
        guard SyncPath.isSafeRelative(relativePath) else { throw FileBrowserError.outsideProject(relativePath) }
        let sftp = try await browserSFTPClient()
        try await sftp.remove(at: RemotePath.join(root, relativePath))
    }
}
