//
//  LocalProjectFiles.swift
//  Argos
//
//  Lado Mac de "Enviar al Mac": recorrer la copia local (con las mismas exclusiones
//  que el servidor) y fijar fecha/permisos de los archivos descargados para que, al
//  volver, solo cuenten como cambiados los que de verdad se editaron en el Mac.
//

import Foundation

enum LocalProjectFiles {

    /// Archivos y enlaces de `root` (rutas relativas), saltando carpetas excluidas.
    static func scan(root: URL) throws -> [SyncFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        var files: [SyncFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = relativePath(of: url, rootPath: rootPath)
            if values.isDirectory == true, values.isSymbolicLink != true {
                if SyncExclusions.directories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard SyncPath.isSafeRelative(relative), !SyncExclusions.isExcluded(relative) else { continue }
            if let file = try fileInfo(at: url.path, relative: relative), !SyncExclusions.isUnsafeGitEntry(file) {
                files.append(file)
            }
        }
        return SyncGitFilter.apply(files).sorted { $0.path < $1.path }
    }

    /// Info de un archivo o enlace (sin seguir el enlace).
    static func fileInfo(at path: String, relative: String) throws -> SyncFile? {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let type = attributes[.type] as? FileAttributeType
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let mtime = Int(((attributes[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970)
        switch type {
        case .typeSymbolicLink:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            return SyncFile(path: relative, size: UInt64(target.utf8.count), mtime: mtime, mode: mode & 0o7777, linkTarget: target)
        case .typeRegular:
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            return SyncFile(path: relative, size: size, mtime: mtime, mode: mode & 0o7777, linkTarget: nil)
        default:
            return nil
        }
    }

    /// Fija permisos y fecha de modificación de un archivo recién descargado.
    static func applyMetadata(of file: SyncFile, at url: URL) throws {
        guard !file.isSymlink else { return }
        try FileManager.default.setAttributes([
            .posixPermissions: NSNumber(value: file.mode),
            .modificationDate: Date(timeIntervalSince1970: TimeInterval(file.mtime)),
        ], ofItemAtPath: url.path)
    }

    /// Crea un enlace simbólico local (reemplazando lo que hubiera).
    static func makeSymlink(_ file: SyncFile, at url: URL) throws {
        guard let target = file.linkTarget else { return }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// ¿La carpeta donde se va a escribir `url` está realmente dentro de `root`, una vez
    /// resueltos los enlaces simbólicos? (Defensa ante enlaces que apunten fuera.)
    static func parentIsInside(_ url: URL, root: URL) -> Bool {
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let realParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return realParent == realRoot || realParent.hasPrefix(realRoot + "/")
    }

    /// ¿El enlace `url`, resuelto del todo, apunta dentro de `root`?
    static func resolvesInside(_ url: URL, root: URL) -> Bool {
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        return real == realRoot || real.hasPrefix(realRoot + "/")
    }

    /// Reconstruye un config de git descargado (`raw`, temporal) en `destination` con la
    /// lista blanca de `GitConfigSanitizer`. Fail-closed: pase lo que pase, el archivo
    /// crudo se borra y solo existe el reconstruido (o ninguno).
    static func rebuildGitConfig(from raw: URL, to destination: URL) throws {
        defer { try? FileManager.default.removeItem(at: raw) }
        guard let text = String(data: try Data(contentsOf: raw), encoding: .utf8) else {
            try? FileManager.default.removeItem(at: destination)
            return
        }
        try GitConfigSanitizer.rebuild(text).text.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// URL local de una ruta relativa, garantizando que queda DENTRO de `root`.
    static func url(for relative: String, in root: URL) -> URL? {
        guard SyncPath.isSafeRelative(relative) else { return nil }
        let url = root.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        return url.path.hasPrefix(rootPath + "/") ? url : nil
    }

    private static func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
    }
}
