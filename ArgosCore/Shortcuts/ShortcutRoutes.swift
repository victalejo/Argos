//
//  ShortcutRoutes.swift
//  ArgosCore
//
//  Rutas para abrir un proyecto desde fuera de la app (atajo «Abrir proyecto»,
//  Spotlight, acciones rápidas del icono). Reutilizan `NotificationRoute`, así que pasan
//  por el mismo camino que un aviso tocado: respetan el bloqueo con Face ID y esperan a
//  que la lista del servidor esté cargada.
//

import Foundation

extension NotificationRoute.Tab {
    var detailMode: DetailMode {
        switch self {
        case .terminal: return .terminal
        case .files: return .files
        case .changes: return .changes
        case .agent: return .agent
        }
    }
}

extension NotificationRoute {
    /// Abre `project` en la pestaña `tab`.
    static func open(_ project: CachedProject, tab: Tab = .terminal) -> NotificationRoute {
        NotificationRoute(serverID: project.serverID, session: project.sessionName, projectPath: project.path, tab: tab)
    }

    /// Identificador de una acción rápida o de un resultado de Spotlight: el del proyecto.
    /// Al recibirlo se busca en la caché; si ya no está, no se abre nada.
    static func open(identifier: String, cache: ProjectShortcutCache, tab: Tab = .terminal) -> NotificationRoute? {
        cache.project(withID: identifier).map { open($0, tab: tab) }
    }
}
