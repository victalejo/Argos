//
//  SessionHandle.swift
//  ArgosCore
//
//  Identificador de sesión multi-servidor y modo de la columna de detalle (lógica pura).
//

import Foundation

// MARK: - Identificador de sesión en el contexto multi-servidor

struct SessionHandle: Hashable, Sendable {
    let serverID: Server.ID
    let sessionID: TmuxSession.ID
}

/// Modo de la 3ª columna para una sesión: el terminal tmux (por defecto) o el panel
/// de agente de Claude Code. Es ADITIVO: el terminal no cambia.
enum DetailMode: Hashable, Sendable {
    case terminal
    case files
    /// Cambios de git (status, diff, commit, push).
    case changes
    case agent
}
