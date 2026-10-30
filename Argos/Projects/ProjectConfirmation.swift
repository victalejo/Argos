//
//  ProjectConfirmation.swift
//  Argos
//
//  Acciones de proyecto que piden confirmación antes de ejecutarse.
//

import Foundation

enum ProjectConfirmation: Identifiable {
    /// Matar la sesión del proyecto (el proyecto se conserva).
    case stop(Server, Project)
    /// Quitar el proyecto de Argos (no toca archivos; la sesión, si corre, sigue viva).
    case remove(Server, Project)
    /// Detener todos los proyectos que corren sin estar abiertos en ningún terminal.
    case stopBackground(Server, [Project])

    var id: String {
        switch self {
        case .stop(_, let project): return "stop-\(project.id)"
        case .remove(_, let project): return "remove-\(project.id)"
        case .stopBackground(let server, _): return "stop-bg-\(server.id)"
        }
    }

    var server: Server {
        switch self {
        case .stop(let server, _), .remove(let server, _), .stopBackground(let server, _): return server
        }
    }

    var title: String {
        switch self {
        case .stop(_, let project): return "¿Detener '\(project.name)'?"
        case .remove(_, let project): return "¿Quitar el proyecto '\(project.name)'?"
        case .stopBackground(_, let projects):
            return "¿Detener \(projects.count) \(projects.count == 1 ? "proyecto" : "proyectos") en segundo plano?"
        }
    }

    var message: String {
        switch self {
        case .stop:
            return "Se cerrará su sesión tmux y todo lo que corra en ella (Claude, servidores, builds). "
                + "El proyecto se conserva: al abrirlo de nuevo arranca en la misma carpeta."
        case .remove:
            return "Solo se quita de Argos. Los archivos del servidor no se tocan y, si su sesión "
                + "está corriendo, sigue viva como sesión suelta."
        case .stopBackground(_, let projects):
            return projects.map(\.name).sorted().joined(separator: ", ")
                + "\n\nSe cerrarán sus sesiones para liberar memoria; los proyectos se conservan."
        }
    }

    var actionLabel: String {
        switch self {
        case .stop, .stopBackground: return "Detener"
        case .remove: return "Quitar"
        }
    }
}
