//
//  ClaudeNoticeSuppression.swift
//  Argos
//
//  ¿Se avisa de que Claude terminó / espera en una ventana tmux? Solo se calla lo que
//  el usuario TIENE DELANTE: el terminal de esa sesión con esa ventana activa. Antes se
//  callaba la sesión entera, así que Claude esperando en otra ventana, o mientras se
//  miraban los Archivos del proyecto, pasaba desapercibido (lógica pura).
//

import Foundation

/// Lo que hay en pantalla: el terminal de `session` mostrando la ventana `window`.
struct TerminalFocus: Equatable, Sendable {
    let serverID: UUID
    let session: String
    /// Ventana activa en el terminal (`nil` mientras no se conocen las ventanas).
    let window: Int?
}

enum ClaudeNoticeSuppression {
    /// Avisos que sobreviven al foco actual (`nil` = no se ve ningún terminal).
    static func notices(
        _ transitions: [ClaudeTransition],
        serverID: UUID,
        focus: TerminalFocus?
    ) -> [ClaudeTransition] {
        transitions.filter { !isVisible($0, serverID: serverID, focus: focus) }
    }

    /// La ventana de la transición está a la vista. Sin saber aún la ventana activa se
    /// supone que es esa (al abrir el terminal aún no se han leído las ventanas, y avisar
    /// de lo que el usuario acaba de abrir sería molesto).
    static func isVisible(_ transition: ClaudeTransition, serverID: UUID, focus: TerminalFocus?) -> Bool {
        guard let focus, focus.serverID == serverID, focus.session == transition.session else { return false }
        return focus.window.map { $0 == transition.window } ?? true
    }
}
