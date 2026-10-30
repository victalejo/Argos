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
        if isGitExecutionVector(components) { return true }
        return components.dropLast().contains { directories.contains($0) }
    }

    /// Hooks de git (en cualquier repo, también submódulos `.git/modules/*/hooks`): git los
    /// EJECUTA al usarlo, así que nunca viajan.
    private static func isGitExecutionVector(_ components: [String]) -> Bool {
        let lower = components.map { $0.lowercased() }
        guard let gitIndex = lower.firstIndex(of: ".git") else { return false }
        return lower[(gitIndex + 1)...].contains("hooks")
    }

    /// El config de git del proyecto: se trae RECONSTRUIDO con una lista blanca
    /// (`GitConfigSanitizer`) y NUNCA se sube (no pisa la config del servidor).
    static func isUploadExcluded(_ relativePath: String) -> Bool {
        relativePath.lowercased() == ".git/config"
    }

    /// Un `.git` que no es una carpeta (archivo `gitdir:` o enlace) puede llevar a git a
    /// un repositorio de fuera, con sus hooks: se descarta.
    static func isUnsafeGitEntry(_ file: SyncFile) -> Bool {
        file.path.split(separator: "/").last?.lowercased() == ".git"
    }
}

/// Filtro de metadatos de git por LISTA BLANCA (el servidor no es de confianza: git
/// ejecuta hooks, sigue `commondir`/`gitdir`, usa worktrees y repos bare incrustados…).
///  - Solo se acepta el `.git` de la raíz y, dentro, solo lo necesario para trabajar:
///    HEAD, index, packed-refs, ORIG_HEAD, FETCH_HEAD, objects/, refs/, logs/,
///    info/exclude y config (este último se reconstruye).
///  - Cualquier `.git` anidado (submódulos, repos dentro del proyecto) se descarta.
///  - Ningún enlace simbólico cuya ruta pase por un `.git`.
///  - Fuera del `.git` raíz: nunca commondir/gitdir/config.worktree; en carpetas con un
///    HEAD (archivo o enlace) se descartan su config y su hooks/; y no se aceptan enlaces
///    llamados HEAD/objects/refs/config/commondir/gitdir/hooks.
enum SyncGitFilter {
    private static let allowedTopLevel: Set<String> = [
        "head", "index", "packed-refs", "orig_head", "fetch_head", "config",
    ]
    private static let allowedTrees: Set<String> = ["objects", "refs", "logs"]

    /// `components` en minúsculas, con `components[0] == ".git"`.
    static func isAllowedGitPath(_ components: [String]) -> Bool {
        guard components.count >= 2 else { return false }
        if components.count == 2 { return allowedTopLevel.contains(components[1]) }
        if allowedTrees.contains(components[1]) { return true }
        return components.count == 3 && components[1] == "info" && components[2] == "exclude"
    }

    /// Fuera del `.git` raíz: nunca viajan (git los usa para redirigir a otro repo).
    private static let neverOutsideRoot: Set<String> = ["commondir", "gitdir", "config.worktree"]
    /// Fuera del `.git` raíz: no se aceptan como enlaces simbólicos.
    private static let noSymlinkNames: Set<String> = ["head", "objects", "refs", "config", "commondir", "gitdir", "hooks"]

    static func apply(_ files: [SyncFile]) -> [SyncFile] {
        let lowerPaths = files.map { $0.path.lowercased() }
        // Carpetas con un HEAD (archivo o enlace): git podría tratarlas como repo, así que
        // su config y sus hooks/ no viajan. No depende de objects/ ni refs/ (esquivables).
        let gitLikeDirectories = Set(lowerPaths.compactMap { path -> String? in
            let components = path.split(separator: "/")
            guard components.last == "head" else { return nil }
            return components.dropLast().joined(separator: "/")
        })

        return zip(files, lowerPaths).compactMap { file, lower in
            let components = lower.split(separator: "/").map(String.init)
            if let gitIndex = components.firstIndex(of: ".git") {
                guard gitIndex == 0, !file.isSymlink, isAllowedGitPath(components) else { return nil }
                return file
            }
            guard let name = components.last else { return nil }
            if neverOutsideRoot.contains(name) { return nil }
            if file.isSymlink && noSymlinkNames.contains(name) { return nil }
            for index in components.indices {
                let directory = components[..<index].joined(separator: "/")
                guard gitLikeDirectories.contains(directory) else { continue }
                let rest = components[index...]
                if rest.first == "hooks" { return nil }
                if rest.count == 1 && (name == "config") { return nil }
            }
            return file
        }
    }
}

/// Reconstruye un config de git con una LISTA BLANCA de claves seguras (remotos, ramas,
/// usuario y ajustes básicos de `core` con valores simples). Todo lo demás se descarta:
/// claves desconocidas, `include`/`includeIf`, filtros, hooks, comandos, y cualquier
/// línea que no se entienda (fail-closed). Escribe un archivo nuevo, no copia líneas.
enum GitConfigSanitizer {

    struct Entry: Equatable {
        let section: String
        let subsection: String?
        let key: String
        let value: String
    }

    private static let simpleValue = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))

    static func isAllowed(_ entry: Entry) -> Bool {
        let value = entry.value
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let isSimple = !value.isEmpty && value.unicodeScalars.allSatisfy { simpleValue.contains($0) }
        switch (entry.section, entry.subsection != nil, entry.key) {
        case ("core", false, "repositoryformatversion"), ("core", false, "bare"), ("core", false, "filemode"),
             ("core", false, "ignorecase"), ("core", false, "logallrefupdates"), ("core", false, "precomposeunicode"),
             ("core", false, "symlinks"):
            return isSimple
        case ("extensions", false, "objectformat"):
            return value == "sha1" || value == "sha256"
        case ("remote", true, "url"), ("remote", true, "pushurl"):
            let lower = value.lowercased()
            return !lower.hasPrefix("ext::") && !lower.hasPrefix("fd::") && !value.hasPrefix("-")
        case ("remote", true, "fetch"), ("remote", true, "push"):
            return !value.isEmpty && !value.contains(" ")
        case ("branch", true, "remote"), ("branch", true, "merge"), ("branch", true, "rebase"),
             ("init", false, "defaultbranch"), ("pull", false, "rebase"), ("pull", false, "ff"),
             ("push", false, "default"), ("push", false, "autosetupremote"):
            return isSimple
        case ("user", false, "name"), ("user", false, "email"):
            return !value.isEmpty
        default:
            return false
        }
    }

    /// Entradas que se entienden sin ambigüedad; lo dudoso se descarta.
    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var section: String?
        var subsection: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                (section, subsection) = parseHeader(line) ?? (nil, nil)
                continue
            }
            guard let section, !line.hasSuffix("\\") else { continue }  // sin continuaciones
            let key: String
            let rawValue: String
            if let equals = line.firstIndex(of: "=") {
                key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            } else {
                key = line.lowercased()
                rawValue = "true"
            }
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                  let value = unquote(rawValue) else { continue }
            entries.append(Entry(section: section, subsection: subsection, key: key, value: value))
        }
        return entries
    }

    /// Config nuevo solo con las entradas permitidas.
    static func rebuild(_ text: String) -> (text: String, removed: Int) {
        let all = parse(text)
        let allowed = all.filter(isAllowed)
        var output: [String] = []
        var currentHeader: String?
        for entry in allowed {
            let header = entry.subsection.map { "[\(entry.section) \"\(escape($0))\"]" } ?? "[\(entry.section)]"
            if header != currentHeader {
                output.append(header)
                currentHeader = header
            }
            output.append("\t\(entry.key) = \"\(escape(entry.value))\"")
        }
        let totalLines = text.split(separator: "\n").filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("[") && !t.hasPrefix("#") && !t.hasPrefix(";")
        }.count
        return (output.joined(separator: "\n") + "\n", max(0, totalLines - allowed.count))
    }

    private static func parseHeader(_ line: String) -> (String, String?)? {
        guard line.hasSuffix("]") else { return nil }
        let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if let quote = inner.firstIndex(of: "\"") {
            let name = inner[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
            let rest = inner[inner.index(after: quote)...]
            guard rest.hasSuffix("\""), !rest.dropLast().contains("\""), !rest.contains("\\") else { return nil }
            return (name, String(rest.dropLast()))
        }
        let parts = inner.split(separator: ".", maxSplits: 1).map(String.init)
        return (parts[0].lowercased(), parts.count > 1 ? parts[1].lowercased() : nil)
    }

    /// Quita comillas y el comentario final; descarta valores con escapes raros.
    private static func unquote(_ raw: String) -> String? {
        var result = ""
        var inQuotes = false
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\"":
                inQuotes.toggle()
            case "\\":
                guard let next = iterator.next(), next == "\"" || next == "\\" else { return nil }
                result.append(next)
            case "#", ";":
                if inQuotes {
                    result.append(character)
                } else {
                    return result.trimmingCharacters(in: .whitespaces)   // comentario final
                }
            default:
                result.append(character)
            }
        }
        return inQuotes ? nil : result.trimmingCharacters(in: .whitespaces)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
        // Sin distinguir mayúsculas: el sistema de archivos del Mac no las distingue
        // ("A" y "a" son la misma carpeta).
        let links = Set(files.filter(\.isSymlink).map { $0.path.lowercased() })
        guard !links.isEmpty else { return files }
        return files.filter { file in
            let path = file.path.lowercased()
            return !links.contains { path.hasPrefix($0 + "/") }
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
        SyncGitFilter.apply(parseRecords(output))
    }

    private static func parseRecords(_ output: String) -> [SyncFile] {
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
            if SyncExclusions.isUploadExcluded(path) { continue }
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
