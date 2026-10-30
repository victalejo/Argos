//
//  SSHFileBrowser.swift
//  Argos
//
//  Acceso de SOLO LECTURA a los archivos del proyecto por SFTP (sobre la conexión SSH
//  existente): listar carpetas, leer archivos (con tope de tamaño) e indexar rutas para
//  la búsqueda rápida (⌘P). Todas las rutas se resuelven con `realpath` y se exige que
//  queden dentro de la carpeta del proyecto: un symlink no permite salir de ella.
//

import Foundation
@preconcurrency import Citadel
import NIOCore

/// Contenido leído de un archivo remoto.
struct RemoteFileContent: Sendable {
    let data: Data
    let size: UInt64
    let modified: Date?
    /// `true` si el archivo es más grande que lo leído.
    let isTruncated: Bool
}

enum FileBrowserError: LocalizedError, Equatable {
    case outsideProject(String)

    var errorDescription: String? {
        switch self {
        case .outsideProject(let path):
            return "'\(path)' está fuera de la carpeta del proyecto (¿un enlace simbólico?)."
        }
    }
}

extension SSHService {

    /// SFTP del explorador, reutilizado mientras la conexión SSH siga siendo la misma.
    private func browserSFTP() async throws -> SFTPClient {
        let client = try await connectedClient()
        if let sftp = fileSFTP, sftp.isActive, fileSFTPOwner == ObjectIdentifier(client) {
            return sftp
        }
        let sftp = try await client.openSFTP()
        fileSFTP = sftp
        fileSFTPOwner = ObjectIdentifier(client)
        return sftp
    }

    /// Ruta real (symlinks resueltos) comprobando que queda dentro de `root`.
    private func containedRealPath(_ path: String, root: String, sftp: SFTPClient) async throws -> String {
        let realRoot = try await sftp.getRealPath(atPath: root)
        let real = try await sftp.getRealPath(atPath: path)
        guard RemotePath.isInside(real, root: realRoot) else { throw FileBrowserError.outsideProject(path) }
        return real
    }

    /// Entradas de `path` (ordenadas, sin `.`/`..`). `root` acota la navegación.
    func listRemoteDirectory(_ path: String, root: String) async throws -> [RemoteFileEntry] {
        let sftp = try await browserSFTP()
        let real = try await containedRealPath(path, root: root, sftp: sftp)
        let names = try await sftp.listDirectory(atPath: real)
        let entries = names.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                RemoteFileEntry(
                    name: component.filename,
                    parent: path,
                    permissions: component.attributes.permissions,
                    size: component.attributes.size,
                    modified: component.attributes.accessModificationTime?.modificationTime
                )
            }
        return RemoteFileEntry.sorted(entries)
    }

    /// Lee hasta `maxBytes` de un archivo del proyecto.
    func readRemoteFile(_ path: String, root: String, maxBytes: UInt64) async throws -> RemoteFileContent {
        let sftp = try await browserSFTP()
        let real = try await containedRealPath(path, root: root, sftp: sftp)
        let attributes = try await sftp.getAttributes(at: real)
        let size = attributes.size ?? 0
        let limit = min(size, maxBytes)

        var buffer = ByteBuffer()
        try await sftp.withFile(filePath: real, flags: .read) { file in
            // Por bloques: los servidores SFTP suelen devolver como mucho ~256 KB por read.
            while UInt64(buffer.readableBytes) < limit {
                let remaining = limit - UInt64(buffer.readableBytes)
                var chunk = try await file.read(
                    from: UInt64(buffer.readableBytes),
                    length: UInt32(min(remaining, 256 * 1024))
                )
                guard chunk.readableBytes > 0 else { break }   // EOF
                buffer.writeBuffer(&chunk)
            }
        }
        return RemoteFileContent(
            data: Data(buffer.readableBytesView),
            size: size,
            modified: attributes.accessModificationTime?.modificationTime,
            isTruncated: size > UInt64(buffer.readableBytes)
        )
    }

    /// Máximo de rutas indexadas para la búsqueda rápida.
    static let fileIndexLimit = 20_000

    /// Comando del índice: rutas relativas de archivos, saltando carpetas pesadas.
    static func fileIndexCommand(root: String) -> String {
        let prune = RemoteFileEntry.noisyDirectories.sorted()
            .map { "-name \(ShellQuoting.singleQuoted($0))" }
            .joined(separator: " -o ")
        return "cd \(ShellQuoting.singleQuoted(root)) && find . \\( \(prune) \\) -prune -o -type f -print "
            + "2>/dev/null | head -n \(fileIndexLimit)"
    }

    /// Rutas relativas de los archivos del proyecto (para ⌘P).
    func indexProjectFiles(root: String) async throws -> [String] {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.fileIndexCommand(root: root))
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
            .filter { !$0.isEmpty }
    }
}
