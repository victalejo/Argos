//
//  AgentWorkingDirStore.swift
//  Argos
//
//  Recuerda el último directorio de trabajo del agente por servidor, para no tener que
//  reescribir la ruta cada vez. Persistido en UserDefaults (no es secreto).
//

import Foundation

enum AgentWorkingDirStore {
    private static func key(for serverID: UUID) -> String {
        "agent.workingdir.\(serverID.uuidString)"
    }

    /// Última carpeta usada en este servidor, o `~` por defecto.
    static func directory(for serverID: UUID) -> String {
        UserDefaults.standard.string(forKey: key(for: serverID)) ?? "~"
    }

    /// Guarda la carpeta elegida/usada para este servidor.
    static func setDirectory(_ directory: String, for serverID: UUID) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: key(for: serverID))
    }
}
