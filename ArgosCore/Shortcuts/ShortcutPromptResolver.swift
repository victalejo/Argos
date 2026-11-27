//
//  ShortcutPromptResolver.swift
//  ArgosCore
//
//  Texto que manda el atajo «Pedir a Claude» (lógica pura): un encargo guardado de la
//  biblioteca (leído del servidor al ejecutar, con las variables ya rellenas), lo escrito
//  en el atajo, o ambos (el guardado primero y lo escrito detrás, como añadido).
//

import Foundation

enum ShortcutPromptResolver {
    /// El prompt guardado `id` del proyecto de `projectPath` (o común). Lanza si ya no está.
    static func savedPrompt(id: String, report: ProjectsLoadReport, projectPath: String) throws -> SavedPrompt {
        let projectID = report.projects.first { $0.path == projectPath }?.id
        guard let prompt = report.prompts.prompt(id: id, project: projectID) else { throw ShortcutError.promptNotFound }
        return prompt
    }

    /// Une el texto guardado (ya expandido) y el escrito; valida el resultado.
    static func combined(saved: String?, typed: String?) throws -> String {
        let parts = [saved, typed]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return try ShortcutTask.validated(parts.joined(separator: "\n\n"))
    }
}
