//
//  RemoteFileEntry.swift
//  Argos
//
//  Modelo (lógica pura) del explorador de archivos remoto: entradas de un directorio
//  leídas por SFTP, orden (carpetas primero, orden natural), carpetas que se ocultan
//  por defecto y contención de rutas dentro de la carpeta del proyecto.
//

import Foundation

/// Una entrada de directorio del servidor.
struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory
        case file
        case symlink
    }

    let name: String
    /// Ruta absoluta en el servidor.
    let path: String
    let kind: Kind
    let size: UInt64?
    let modified: Date?

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
    var isHidden: Bool { name.hasPrefix(".") }

    // Bits de tipo de `st_mode` (POSIX).
    private static let typeMask: UInt32 = 0o170000
    private static let directoryBits: UInt32 = 0o040000
    private static let symlinkBits: UInt32 = 0o120000

    /// Construye la entrada a partir de los atributos SFTP (`permissions` = `st_mode`).
    init(name: String, parent: String, permissions: UInt32?, size: UInt64?, modified: Date?) {
        self.name = name
        self.path = RemotePath.join(parent, name)
        switch (permissions ?? 0) & Self.typeMask {
        case Self.directoryBits: kind = .directory
        case Self.symlinkBits: kind = .symlink
        default: kind = .file
        }
        self.size = size
        self.modified = modified
    }

    init(name: String, path: String, kind: Kind, size: UInt64? = nil, modified: Date? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    /// Carpetas pesadas o generadas que se ocultan salvo que el usuario las muestre.
    static let noisyDirectories: Set<String> = [
        ".git", "node_modules", ".next", ".nuxt", "dist", "build", "out", ".turbo",
        ".cache", "__pycache__", ".venv", "venv", ".mypy_cache", ".pytest_cache",
        "target", ".gradle", "Pods", "DerivedData", ".svelte-kit", "coverage",
    ]

    /// ¿Se muestra con la configuración actual?
    func isVisible(showHidden: Bool) -> Bool {
        if showHidden { return true }
        if isHidden { return false }
        return !(isDirectory && Self.noisyDirectories.contains(name))
    }

    /// Carpetas primero; dentro de cada grupo, orden natural ("file2" < "file10").
    static func sorted(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Utilidades de rutas POSIX del servidor (no del Mac).
enum RemotePath {
    static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// ¿`path` está dentro de `root` (o es `root`)? Compara por componentes, así
    /// "/srv/app-old" NO cuenta como dentro de "/srv/app".
    static func isInside(_ path: String, root: String) -> Bool {
        let normalizedRoot = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return path == normalizedRoot || path.hasPrefix(normalizedRoot == "/" ? "/" : normalizedRoot + "/")
    }

    /// Ruta relativa a `root` para mostrarla ("src/app/page.tsx").
    static func relative(_ path: String, to root: String) -> String {
        guard isInside(path, root: root), path != root else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return String(path.dropFirst(prefix.count))
    }

    static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}
