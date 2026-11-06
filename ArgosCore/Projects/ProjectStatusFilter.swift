//
//  ProjectStatusFilter.swift
//  Argos
//
//  Filtro de la barra lateral por estado del proyecto. Lógica pura (testeable): cada
//  proyecto cae en UNA sola categoría, en este orden de prioridad:
//    1. En el Mac      → enviado al Mac (aunque quede una sesión en el servidor).
//    2. Abiertas       → su terminal está abierto en Argos (o conectando / con error).
//    3. Segundo plano  → corre y está abierta en otro cliente (otra terminal, otro Mac).
//    4. Dormidas       → corre en el servidor pero nadie está conectado.
//    5. Detenidas      → sin sesión tmux: no consume recursos.
//

import Foundation

/// Estado de un proyecto (o sesión suelta) a efectos del filtro.
enum ProjectStatus: Sendable, Equatable {
    case open
    case background
    case dormant
    case stopped
    case onMac

    /// - Parameters:
    ///   - connection: estado del terminal si la sesión corre; `nil` = sin sesión tmux.
    ///   - onMac: el proyecto está enviado al Mac.
    static func of(connection: SessionConnectionState?, onMac: Bool) -> ProjectStatus {
        if onMac { return .onMac }
        switch connection {
        case .none: return .stopped
        case .live, .connecting, .error: return .open
        case .attachedElsewhere: return .background
        case .dormant: return .dormant
        }
    }
}

/// Opción elegida en el filtro de la barra lateral.
enum ProjectStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case open
    case dormant
    case stopped
    case onMac
    case background

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Todos"
        case .open: return "Abiertas"
        case .dormant: return "Dormidas"
        case .stopped: return "Detenidas"
        case .onMac: return "En el Mac"
        case .background: return "Segundo plano"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .open: return "play.circle"
        case .dormant: return "moon.zzz"
        case .stopped: return "stop.circle"
        case .onMac: return "laptopcomputer"
        case .background: return "rectangle.on.rectangle"
        }
    }

    var help: String {
        switch self {
        case .all: return "Todos los proyectos"
        case .open: return "Con el terminal abierto en Argos"
        case .dormant: return "Corren en el servidor, pero nadie está conectado"
        case .stopped: return "Sin sesión en el servidor: no consumen recursos"
        case .onMac: return "Enviados al Mac"
        case .background: return "Corren y están abiertas en otro cliente (otra terminal u otro Mac)"
        }
    }

    func includes(_ status: ProjectStatus) -> Bool {
        switch self {
        case .all: return true
        case .open: return status == .open
        case .dormant: return status == .dormant
        case .stopped: return status == .stopped
        case .onMac: return status == .onMac
        case .background: return status == .background
        }
    }
}
