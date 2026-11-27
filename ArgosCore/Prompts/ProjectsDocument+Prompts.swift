//
//  ProjectsDocument+Prompts.swift
//  ArgosCore
//
//  Biblioteca de encargos dentro de projects.json (cambio ADITIVO, sin subir `version`):
//   - `prompts` del archivo: los comunes del servidor;
//   - `prompts` de cada proyecto: los suyos;
//   - `promptsSeeded`: los ejemplos ya se sembraron.
//  Las versiones publicadas conservan estas claves porque guardan las desconocidas
//  (`extra` y el objeto de cada proyecto). Sin prompts, los bytes son los de siempre.
//

import Foundation

enum PromptLibraryError: LocalizedError, Equatable {
    /// La lista existe pero no tiene la forma que entiende esta versión.
    case unreadableList
    case projectNotFound

    var errorDescription: String? {
        switch self {
        case .unreadableList:
            return String(localized: "La biblioteca de encargos del servidor tiene un formato que esta versión de Argos no entiende; no se ha cambiado. Actualiza Argos.")
        case .projectNotFound:
            return String(localized: "El proyecto ya no está en el servidor.")
        }
    }
}

extension ProjectsDocument {
    static let promptsKey = "prompts"
    static let promptsSeededKey = "promptsSeeded"

    var promptLibrary: PromptLibrary {
        var byProject: [UUID: PromptList] = [:]
        for case .valid(let project, let raw) in entries where byProject[project.id] == nil {
            let list = PromptList.parse(raw[Self.promptsKey])
            if !list.isEmpty || !list.isWritable { byProject[project.id] = list }
        }
        return PromptLibrary(
            common: PromptList.parse(extra[Self.promptsKey]),
            byProject: byProject,
            seeded: extra[Self.promptsSeededKey]?.boolValue == true
        )
    }

    /// Aplica `change` a la lista de `scope` (lanza si no se puede reescribir sin perder nada).
    func updatingPrompts(_ scope: PromptScope, _ change: (PromptList) throws -> PromptList) throws -> ProjectsDocument {
        guard !isNewerThanSupported else { throw ProjectError.newerFormat(version) }
        var copy = self
        switch scope {
        case .common:
            let current = PromptList.parse(extra[Self.promptsKey])
            guard current.isWritable else { throw PromptLibraryError.unreadableList }
            copy.extra[Self.promptsKey] = try change(current).json
        case .project(let id):
            guard let index = entries.firstIndex(where: { if case .valid(let project, _) = $0 { return project.id == id } else { return false } }),
                  case .valid(let project, var raw) = entries[index]
            else { throw PromptLibraryError.projectNotFound }
            let current = PromptList.parse(raw[Self.promptsKey])
            guard current.isWritable else { throw PromptLibraryError.unreadableList }
            raw[Self.promptsKey] = try change(current).json
            copy.entries[index] = .valid(project, raw: raw)
        }
        return copy
    }

    /// Pone los ejemplos una sola vez (los que falten por `id`) y deja la marca. Ya
    /// sembrado, o con una lista común ilegible, no cambia nada.
    func seedingExamplesIfNeeded() throws -> ProjectsDocument {
        guard !promptLibrary.seeded else { return self }
        guard PromptList.parse(extra[Self.promptsKey]).isWritable else { return self }
        var seeded = try updatingPrompts(.common) { list in
            PromptSeed.examples.reduce(list) { partial, example in
                partial.prompts.contains { $0.id == example.id } ? partial : partial.upserting(example)
            }
        }
        seeded.extra[Self.promptsSeededKey] = .bool(true)
        return seeded
    }
}
