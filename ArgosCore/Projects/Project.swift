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
    /// Si el proyecto se envió a un Mac para trabajar allí ("Enviar al Mac").
    var macCheckout: MacCheckout?

    init(
        id: UUID = UUID(),
        name: String,
        group: String? = nil,
        path: String,
        startupCommand: String? = nil,
        createdAt: Date = Date(),
        macCheckout: MacCheckout? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.path = path
        self.startupCommand = startupCommand
        self.createdAt = createdAt
        self.macCheckout = macCheckout
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

/// Marca de "este proyecto se está trabajando en un Mac". Vive en projects.json del
/// servidor, así que la ven todos los Mac con Argos.
struct MacCheckout: Codable, Hashable, Sendable {
    /// Nombre del Mac (para mostrar "En el Mac de …").
    let macName: String
    /// Identificador estable del Mac que lo tiene (para saber si es ESTE Mac).
    let macID: String
    let date: Date
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
    /// El archivo lo escribió una versión más nueva de Argos (formato `n`).
    case newerFormat(Int)
    /// Otro dispositivo lo cambió una y otra vez mientras se guardaba.
    case writeConflict
    case noBackup
    case invalidBackup

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return String(localized: "~/.config/argos/projects.json del servidor está dañado (no es JSON válido) y Argos no lo ha modificado. Restaura la copia anterior (projects.json.argos-backup) desde Argos o corrige el archivo en el servidor.")
        case .duplicateName(let name):
            return String(localized: "Ya existe un proyecto o sesión llamado '\(name)' en este servidor.")
        case .missingFolder(let path):
            return String(localized: "La carpeta '\(path)' ya no existe en el servidor. Edita el proyecto para elegir otra.")
        case .invalidPath:
            return String(localized: "La carpeta debe ser una ruta absoluta del servidor (empieza por '/').")
        case .newerFormat(let version):
            return String(localized: "Los proyectos de este servidor los guardó una versión más nueva de Argos (formato \(version)). Actualiza Argos en este dispositivo para poder modificarlos.")
        case .writeConflict:
            return String(localized: "Otro dispositivo está cambiando los proyectos de este servidor a la vez. Vuelve a intentarlo en unos segundos.")
        case .noBackup:
            return String(localized: "No hay copia anterior de los proyectos (projects.json.argos-backup) en este servidor.")
        case .invalidBackup:
            return String(localized: "La copia anterior de los proyectos también está dañada; no se ha restaurado. Corrige el archivo en el servidor.")
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
