//
//  SavedPromptMenu.swift
//  ArgosUI
//
//  Selector de la biblioteca de encargos (Mac e iPhone/iPad): un menú con los prompts del
//  proyecto y los comunes. Lo usan Encargos, Tareas programadas y el panel de agente.
//

import SwiftUI

struct SavedPromptMenu: View {
    let prompts: [SavedPrompt]
    let onPick: (SavedPrompt) -> Void

    var body: some View {
        Menu {
            ForEach(prompts) { (prompt: SavedPrompt) in
                Button(prompt.displayTitle) { onPick(prompt) }
            }
        } label: {
            Label("Biblioteca", systemImage: "books.vertical")
        }
        .disabled(prompts.isEmpty)
        .help("Usar un encargo guardado de la biblioteca")
    }
}

/// Lo que necesita una caja de mensaje para ofrecer la biblioteca: los prompts y cómo
/// rellenar sus variables en el servidor.
struct SavedPromptContext {
    let prompts: [SavedPrompt]
    let expand: @MainActor (String) async -> String
}

private struct SavedPromptContextKey: EnvironmentKey {
    static let defaultValue: SavedPromptContext? = nil
}

extension EnvironmentValues {
    var savedPromptContext: SavedPromptContext? {
        get { self[SavedPromptContextKey.self] }
        set { self[SavedPromptContextKey.self] = newValue }
    }
}

extension SavedPromptContext {
    /// Los del proyecto (si lo hay) y los comunes, con las variables de su carpeta.
    @MainActor
    static func make(library: PromptLibrary, projectID: UUID?, service: any SSHServicing, path: String) -> SavedPromptContext {
        SavedPromptContext(prompts: library.prompts(forProject: projectID)) { (text: String) async -> String in
            await PromptExpansion.expand(text, service: service, projectPath: path)
        }
    }
}
