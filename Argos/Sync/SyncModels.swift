//
//  SyncModels.swift
//  Argos
//
//  "Enviar al Mac" / "Enviar al servidor" (lógica pura): qué archivos viajan, cómo
//  se lee el listado del servidor y cómo se decide qué subir, qué borrar y qué es un
//  conflicto, comparando contra el MANIFIESTO (el estado del servidor en el momento en
//  que el proyecto se envió al Mac).
//

import Foundation

/// Un archivo (o enlace simbólico) del proyecto, con ruta RELATIVA a su carpeta.
struct SyncFile: Codable, Hashable, Sendable {
    let path: String
    let size: UInt64
    /// Segundos enteros desde 1970 (el Mac y el servidor se igualan al transferir).
    let mtime: Int
    /// Permisos POSIX (p. ej. 0o755 para un script ejecutable).
    let mode: UInt16
    /// Destino si es un enlace simbólico; `nil` si es un archivo normal.
    let linkTarget: String?

    var isSymlink: Bool { linkTarget != nil }

    /// ¿Es "el mismo" archivo? (tamaño, fecha, permisos y destino del enlace).
    func matches(_ other: SyncFile?) -> Bool {
        guard let other else { return false }
        return size == other.size && mtime == other.mtime && mode == other.mode && linkTarget == other.linkTarget
    }
}

/// Qué NO viaja: carpetas que se regeneran (dependencias, builds, cachés). `.git` SÍ
/// viaja (para poder hacer commits en el Mac).
enum SyncExclusions {
    static let directories: Set<String> = RemoteFileEntry.noisyDirectories.subtracting([".git"])
    static let files: Set<String> = [".DS_Store"]

    static func isExcluded(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let last = components.last else { return true }
        if files.contains(last) { return true }
        return components.dropLast().contains { directories.contains($0) }
    }
}

/// Validación de rutas relativas que vienen del servidor (no confiables): nada de
/// rutas absolutas ni `..` que permitan escribir fuera de la carpeta del proyecto.
enum SyncPath {
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }
}

extension SyncPath {
    /// Quita las entradas que cuelgan de un enlace simbólico del propio listado: escribir
    /// "enlace/archivo" seguiría el enlace y podría escribir FUERA de la carpeta.
    static func withoutPathsUnderSymlinks(_ files: [SyncFile]) -> [SyncFile] {
        let links = Set(files.filter(\.isSymlink).map(\.path))
        guard !links.isEmpty else { return files }
        return files.filter { file in
            !links.contains { file.path.hasPrefix($0 + "/") }
        }
    }

    /// ¿Se puede recrear este enlace sin apuntar fuera del proyecto? Solo destinos
    /// relativos que, resueltos desde la carpeta del enlace, quedan dentro de la raíz.
    static func isSafeSymlink(path: String, target: String) -> Bool {
        guard isSafeRelative(path), !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var stack = path.split(separator: "/").dropLast().map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return false }
                stack.removeLast()
            default:
                stack.append(String(component))
            }
        }
        return true
    }
}

/// Listado de archivos del servidor (`find … -printf`).
enum ServerFileList {
    /// Comando: un registro por archivo/enlace separado por NUL, con la ruta al FINAL
    /// (`tipo⇥tamaño⇥mtime⇥modo⇥destino⇥ruta␀`) para tolerar tabuladores en los nombres.
    static func command(root: String) -> String {
        let prune = SyncExclusions.directories.sorted()
            .map { "-name \(ShellQuoting.singleQuoted($0))" }
            .joined(separator: " -o ")
        return "cd \(ShellQuoting.singleQuoted(root)) && find . \\( \(prune) \\) -prune -o "
            + "\\( -type f -o -type l \\) -printf '%y\\t%s\\t%T@\\t%m\\t%l\\t%P\\0'"
    }

    static func parse(_ output: String) -> [SyncFile] {
        output.split(separator: "\0").compactMap { record in
            let fields = record.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6,
                  let size = UInt64(fields[1]),
                  let mtime = Double(fields[2]), mtime.isFinite, mtime >= 0, mtime < 1e11,
                  let mode = UInt16(fields[3], radix: 8)
            else { return nil }
            let path = String(fields[5])
            guard SyncPath.isSafeRelative(path), !SyncExclusions.isExcluded(path) else { return nil }
            let isLink = fields[0] == "l"
            return SyncFile(
                path: path,
                size: size,
                mtime: Int(mtime),
                mode: mode & 0o7777,
                linkTarget: isLink ? String(fields[4]) : nil
            )
        }
    }
}

/// Estado guardado al enviar un proyecto al Mac.
struct SyncManifest: Codable, Equatable, Sendable {
    let projectID: UUID
    let serverID: UUID
    let remoteRoot: String
    /// Carpeta local (ruta POSIX) donde quedó la copia.
    let localPath: String
    let createdAt: Date
    /// Estado del servidor en ese momento, por ruta relativa.
    let files: [String: SyncFile]
    /// Bookmark con alcance de seguridad de la carpeta local (sandbox).
    var localBookmark: Data?
}

/// Un conflicto: el archivo cambió en el Mac Y en el servidor desde el envío.
struct SyncConflict: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case bothModified
        case deletedOnMacModifiedOnServer
        case modifiedOnMacDeletedOnServer
    }
    let path: String
    let kind: Kind
}

/// Qué hará "Enviar al servidor".
struct SyncPlan: Equatable, Sendable {
    /// Archivos del Mac que se suben (versión local).
    var uploads: [SyncFile] = []
    /// Rutas que se borran en el servidor (se borraron en el Mac).
    var deletions: [String] = []
    var conflicts: [SyncConflict] = []
    /// Cambios hechos en el servidor mientras tanto que se CONSERVAN (no se tocan).
    var keptServerChanges: [String] = []

    var isEmpty: Bool { uploads.isEmpty && deletions.isEmpty && conflicts.isEmpty }
}

enum SyncPlanner {

    /// Compara Mac y servidor contra el manifiesto (estado al enviar).
    static func plan(manifest: [String: SyncFile], local: [SyncFile], server: [SyncFile]) -> SyncPlan {
        let localByPath = Dictionary(local.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let serverByPath = Dictionary(server.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let allPaths = Set(manifest.keys).union(localByPath.keys).union(serverByPath.keys)

        var plan = SyncPlan()
        for path in allPaths.sorted() {
            let base = manifest[path]
            let mac = localByPath[path]
            let srv = serverByPath[path]
            let macChanged = !sameState(mac, base)
            let serverChanged = !sameState(srv, base)

            switch (macChanged, serverChanged) {
            case (false, false):
                continue
            case (false, true):
                plan.keptServerChanges.append(path)
            case (true, false):
                if let mac {
                    plan.uploads.append(mac)
                } else if srv != nil {
                    plan.deletions.append(path)
                }
            case (true, true):
                // Mismo resultado en ambos lados (p. ej. el mismo cambio, o borrado en los dos).
                if sameState(mac, srv) { continue }
                let kind: SyncConflict.Kind
                switch (mac, srv) {
                case (nil, _): kind = .deletedOnMacModifiedOnServer
                case (_, nil): kind = .modifiedOnMacDeletedOnServer
                default: kind = .bothModified
                }
                plan.conflicts.append(SyncConflict(path: path, kind: kind))
            }
        }
        return plan
    }

    /// Aplica la decisión del usuario sobre los conflictos: con `preferMac`, la versión
    /// del Mac gana (se sube o se borra en el servidor); si no, se conserva el servidor.
    static func resolving(_ plan: SyncPlan, preferMac: Bool, local: [SyncFile]) -> SyncPlan {
        guard preferMac else {
            var kept = plan
            kept.keptServerChanges += plan.conflicts.map(\.path)
            kept.conflicts = []
            return kept
        }
        let localByPath = Dictionary(local.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved = plan
        for conflict in plan.conflicts {
            if let mac = localByPath[conflict.path] {
                resolved.uploads.append(mac)
            } else if conflict.kind == .deletedOnMacModifiedOnServer {
                resolved.deletions.append(conflict.path)
            }
        }
        resolved.conflicts = []
        return resolved
    }

    private static func sameState(_ lhs: SyncFile?, _ rhs: SyncFile?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let l?, let r?): return l.matches(r)
        default: return false
        }
    }
}
