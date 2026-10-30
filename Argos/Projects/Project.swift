//
//  Project.swift
//  Argos
//
//  Un proyecto es una CARPETA del servidor con nombre propio. La sesión tmux es
//  efímera: se crea al abrir el proyecto (en su carpeta, lanzando el comando de
//  arranque) y se puede detener (kill-session) sin perder el proyecto.
//
//  Los proyectos se guardan EN EL SERVIDOR (`~/.config/argos/projects.json`), así que
//  todos los Mac con Argos ven los mismos. Identidad con tmux: el nombre de la sesión
//  es `grupo/nombre` (o `nombre` sin grupo), la misma convención que ya agrupaba las
//  sesiones, de modo que las sesiones existentes se importan sin renombrarlas.
//

import Foundation

struct Project: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Grupo de la barra lateral ("ia portafolio", "tmh"…), o `nil`.
    var group: String?
    /// Ruta ABSOLUTA de la carpeta en el servidor.
    var path: String
    /// Comando al abrir: `nil` = el predeterminado de Ajustes; `""` = ninguno.
    var startupCommand: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        group: String? = nil,
        path: String,
        startupCommand: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.path = path
        self.startupCommand = startupCommand
        self.createdAt = createdAt
    }

    /// Nombre de la sesión tmux que representa al proyecto mientras corre.
    var sessionName: String {
        guard let group, !group.isEmpty else { return name }
        return "\(group)\(SessionGrouping.separator)\(name)"
    }

    /// Comando de arranque efectivo (`nil` = no lanzar nada).
    func resolvedStartupCommand(default defaultCommand: String) -> String? {
        let command = (startupCommand ?? defaultCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

/// Fichero `projects.json` de un servidor (versionado para poder migrarlo).
struct ProjectsFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var projects: [Project]

    static let empty = ProjectsFile(projects: [])

    static func decode(_ text: String) throws -> ProjectsFile {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        do {
            return try JSONDecoder.projects.decode(ProjectsFile.self, from: Data(text.utf8))
        } catch {
            throw ProjectError.invalidFile
        }
    }

    func encoded() throws -> Data {
        try JSONEncoder.projects.encode(self)
    }
}

enum ProjectError: LocalizedError, Equatable {
    case invalidFile
    case duplicateName(String)
    case missingFolder(String)
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "~/.config/argos/projects.json del servidor no es válido; no se modificó."
        case .duplicateName(let name):
            return "Ya existe un proyecto o sesión llamado '\(name)' en este servidor."
        case .missingFolder(let path):
            return "La carpeta '\(path)' ya no existe en el servidor. Edita el proyecto para elegir otra."
        case .invalidPath:
            return "La carpeta debe ser una ruta absoluta del servidor (empieza por '/')."
        }
    }
}

extension JSONEncoder {
    static let projects: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let projects: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
