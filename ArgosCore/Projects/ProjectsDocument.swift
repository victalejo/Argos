//
//  ProjectsDocument.swift
//  Argos
//
//  `~/.config/argos/projects.json` tal cual está en disco (lógica pura). Lo escriben el
//  Mac, el iPhone/iPad y Android, cada uno quizá con una versión distinta de Argos, así
//  que al reescribirlo:
//   - se CONSERVAN las claves que esta versión no conoce, del archivo y de cada proyecto
//     (y de los objetos anidados, como `macCheckout`);
//   - un proyecto que no se puede leer (sin `createdAt`, fecha rara…) se aparta y se
//     vuelve a escribir tal cual, en vez de invalidar el archivo entero;
//   - si `version` es mayor que la soportada, se puede leer pero NO escribir.
//  El formato no cambia: con solo claves conocidas, los bytes son los de siempre.
//

import Foundation

struct ProjectsDocument: Equatable, Sendable {
    /// Versión de formato que esta app sabe escribir.
    static let supportedVersion = 1

    enum Entry: Equatable, Sendable {
        /// Proyecto legible con su objeto original (para conservar claves desconocidas).
        case valid(Project, raw: [String: JSONValue])
        /// Entrada ilegible: se conserva tal cual.
        case invalid(JSONValue)
    }

    var version: Int
    /// Claves del archivo distintas de `version` y `projects`.
    var extra: [String: JSONValue]
    var entries: [Entry]

    static let empty = ProjectsDocument(version: supportedVersion, extra: [:], entries: [])

    var projects: [Project] {
        entries.compactMap { entry in
            if case .valid(let project, _) = entry { return project }
            return nil
        }
    }

    var invalidCount: Int {
        entries.filter { if case .invalid = $0 { return true } else { return false } }.count
    }

    var isNewerThanSupported: Bool { version > Self.supportedVersion }

    // MARK: - Lectura

    /// Vacío (o solo espacios) = sin proyectos. Lanza `invalidFile` si no es JSON, no es
    /// un objeto, o le falta `version` (entero) o `projects` (lista).
    static func parse(_ text: String) throws -> ProjectsDocument {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              var object = value.objectValue,
              case .int(let version)? = object["version"],
              let items = object["projects"]?.arrayValue
        else { throw ProjectError.invalidFile }
        object["version"] = nil
        object["projects"] = nil
        return ProjectsDocument(version: version, extra: object, entries: items.map(entry))
    }

    private static func entry(_ value: JSONValue) -> Entry {
        guard let raw = value.objectValue,
              let data = try? JSONEncoder().encode(value),
              let project = try? JSONDecoder.projects.decode(Project.self, from: data)
        else { return .invalid(value) }
        return .valid(project, raw: raw)
    }

    // MARK: - Escritura

    /// Documento con `projects` en lugar de los legibles: cada uno conserva las claves
    /// desconocidas de su entrada anterior (mismo `id`) y las ilegibles van al final.
    func replacingProjects(_ projects: [Project]) throws -> ProjectsDocument {
        guard !isNewerThanSupported else { throw ProjectError.newerFormat(version) }
        var rawByID: [UUID: [String: JSONValue]] = [:]
        for case .valid(let project, let raw) in entries where rawByID[project.id] == nil {
            rawByID[project.id] = raw
        }
        let valid = try projects.map { project -> Entry in
            let fresh = try Self.object(for: project)
            let merged = Self.merge(rawByID[project.id] ?? [:], fresh, known: Self.projectKeys)
            return .valid(project, raw: merged)
        }
        let invalid = entries.filter { if case .invalid = $0 { return true } else { return false } }
        return ProjectsDocument(version: version, extra: extra, entries: valid + invalid)
    }

    func encoded() throws -> Data {
        var object = extra
        object["version"] = .int(version)
        object["projects"] = .array(entries.map { entry in
            switch entry {
            case .valid(_, let raw): return .object(raw)
            case .invalid(let value): return value
            }
        })
        return try JSONEncoder.projects.encode(JSONValue.object(object))
    }

    // MARK: - Mezcla

    /// Claves de `Project` y de sus objetos anidados que escribe esta versión.
    static let projectKeys: Set<String> = ["id", "name", "group", "path", "startupCommand", "createdAt", "macCheckout"]
    static let nestedKeys: [String: Set<String>] = ["macCheckout": ["macName", "macID", "date"]]

    private static func object(for project: Project) throws -> [String: JSONValue] {
        let data = try JSONEncoder.projects.encode(project)
        guard let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            throw ProjectError.invalidFile
        }
        return object
    }

    /// `old` con los valores de `fresh`: las claves conocidas mandan (`fresh` sin una
    /// clave conocida = se quitó, p. ej. un opcional a `nil`); las desconocidas de `old`
    /// se quedan. En objetos anidados conocidos se aplica lo mismo un nivel más abajo.
    static func merge(
        _ old: [String: JSONValue], _ fresh: [String: JSONValue], known: Set<String>
    ) -> [String: JSONValue] {
        var result = old
        for key in known { result[key] = nil }
        for (key, value) in fresh {
            if let nested = nestedKeys[key], case .object(let newObject) = value,
               let oldObject = old[key]?.objectValue {
                result[key] = .object(merge(oldObject, newObject, nestedKnown: nested))
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func merge(
        _ old: [String: JSONValue], _ fresh: [String: JSONValue], nestedKnown: Set<String>
    ) -> [String: JSONValue] {
        var result = old
        for key in nestedKnown { result[key] = nil }
        result.merge(fresh) { _, new in new }
        return result
    }
}

/// Resultado de leer projects.json, con lo que hay que avisar.
struct ProjectsLoadReport: Equatable, Sendable {
    let projects: [Project]
    /// Entradas ilegibles apartadas (se conservan en el archivo).
    let skippedEntries: Int
    /// Versión de formato del archivo.
    let fileVersion: Int

    init(projects: [Project], skippedEntries: Int = 0, fileVersion: Int = ProjectsDocument.supportedVersion) {
        self.projects = projects
        self.skippedEntries = skippedEntries
        self.fileVersion = fileVersion
    }

    init(document: ProjectsDocument) {
        self.init(projects: document.projects, skippedEntries: document.invalidCount, fileVersion: document.version)
    }

    /// Aviso para la interfaz (`nil` si no hay nada que decir).
    var warning: String? {
        var parts: [String] = []
        if skippedEntries > 0 {
            parts.append(skippedEntries == 1
                ? "Un proyecto de ~/.config/argos/projects.json no se pudo leer; se conserva en el archivo sin cambios."
                : "\(skippedEntries) proyectos de ~/.config/argos/projects.json no se pudieron leer; se conservan en el archivo sin cambios.")
        }
        if fileVersion > ProjectsDocument.supportedVersion {
            parts.append(ProjectError.newerFormat(fileVersion).errorDescription ?? "")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
