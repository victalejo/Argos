//
//  ProjectListing.swift
//  Argos
//
//  Lógica pura que cruza los proyectos guardados con las sesiones tmux vivas:
//  qué proyectos corren, cuáles están detenidos, qué sesiones no pertenecen a ningún
//  proyecto ("sueltas"), cómo importar sesiones como proyectos y validar cambios.
//

import Foundation

/// Un proyecto con su sesión tmux si está corriendo.
struct ProjectEntry: Identifiable, Hashable, Sendable {
    let project: Project
    /// Sesión viva del proyecto, o `nil` si está detenido.
    let session: TmuxSession?

    var id: UUID { project.id }
    var isRunning: Bool { session != nil }
}

/// Grupo de proyectos para la barra lateral.
struct ProjectGroup: Identifiable, Sendable {
    let name: String
    let entries: [ProjectEntry]
    var id: String { name }
}

enum ProjectListing {

    /// Cruza proyectos y sesiones. Devuelve las entradas (ordenadas por nombre) y las
    /// sesiones que no corresponden a ningún proyecto.
    static func build(
        projects: [Project],
        sessions: [TmuxSession]
    ) -> (entries: [ProjectEntry], looseSessions: [TmuxSession]) {
        let sessionsByName = Dictionary(sessions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = projects
            .map { ProjectEntry(project: $0, session: sessionsByName[$0.sessionName]) }
            .sorted { $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending }
        let projectSessionNames = Set(projects.map(\.sessionName))
        let loose = sessions
            .filter { !projectSessionNames.contains($0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (entries, loose)
    }

    /// Agrupa por `group` (sin grupo -> `SessionGrouping.ungroupedName`), grupos por nombre.
    static func groups(_ entries: [ProjectEntry]) -> [ProjectGroup] {
        let grouped = Dictionary(grouping: entries) { entry -> String in
            let group = entry.project.group?.trimmingCharacters(in: .whitespaces) ?? ""
            return group.isEmpty ? SessionGrouping.ungroupedName : group
        }
        return grouped
            .map { ProjectGroup(name: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                // "General" al final; el resto alfabético.
                if lhs.name == SessionGrouping.ungroupedName { return false }
                if rhs.name == SessionGrouping.ungroupedName { return true }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Candidato de importación: una sesión suelta y la carpeta de su primer panel.
    static func importCandidate(session: TmuxSession, path: String?) -> Project? {
        guard let path, path.hasPrefix("/") else { return nil }
        let (group, short) = SessionGrouping.split(session.name)
        // Solo es un grupo real si había "grupo/nombre" con ambas partes; si no, el nombre
        // completo queda como nombre (así `sessionName` sigue coincidiendo con la sesión).
        let hasGroup = short != session.name && session.name == "\(group)\(SessionGrouping.separator)\(short)"
        return Project(
            name: hasGroup ? short : session.name,
            group: hasGroup ? group : nil,
            path: path,
            startupCommand: nil
        )
    }

    /// Ruta del primer panel (ventana y panel de menor índice) de cada sesión, a partir de
    /// `tmux list-panes -a -F '#{window_index}|#{pane_index}|#{pane_current_path}|#{session_name}'`.
    static func firstPanePaths(listPanesOutput: String) -> [String: String] {
        var best: [String: (window: Int, pane: Int, path: String)] = [:]
        for line in listPanesOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let window = Int(fields[0]), let pane = Int(fields[1]),
                  !fields[3].isEmpty
            else { continue }
            let session = String(fields[3])
            let candidate = (window: window, pane: pane, path: String(fields[2]))
            if let current = best[session], (current.window, current.pane) <= (window, pane) { continue }
            best[session] = candidate
        }
        return best.mapValues(\.path)
    }

    /// Valida un proyecto nuevo o editado contra los demás del servidor y las sesiones
    /// sueltas (el nombre de sesión debe ser único). Devuelve el proyecto normalizado.
    static func validate(
        _ project: Project,
        among projects: [Project],
        looseSessions: [TmuxSession]
    ) throws -> Project {
        var normalized = project
        normalized.name = try SessionNameValidator.validate(project.name)
        // El '/' separa grupo y nombre en la sesión tmux: no puede ir en el nombre.
        if normalized.name.contains(SessionGrouping.separator) {
            throw SessionNameValidator.ValidationError.forbiddenCharacter(SessionGrouping.separator)
        }
        if let group = project.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
            normalized.group = try SessionNameValidator.validate(group)
            if group.contains(SessionGrouping.separator) {
                throw SessionNameValidator.ValidationError.forbiddenCharacter(SessionGrouping.separator)
            }
        } else {
            normalized.group = nil
        }
        normalized.path = project.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.path.hasPrefix("/") else { throw ProjectError.invalidPath }

        let others = projects.filter { $0.id != project.id }.map(\.sessionName)
            + looseSessions.map(\.name)
        if others.contains(normalized.sessionName) {
            throw ProjectError.duplicateName(normalized.sessionName)
        }
        return normalized
    }
}
