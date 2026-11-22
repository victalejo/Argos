//
//  TerminalAttach.swift
//  ArgosCore
//
//  Comando con el que el terminal en vivo se engancha a una sesión tmux y detección de
//  «esa sesión ya no existe». Sin esto, un `tmux attach` a una sesión muerta cerraba el PTY
//  con error y el terminal lo trataba como una caída de red: reintentaba sin fin en vez de
//  decir que la sesión terminó. Lógica pura; Android la porta en `TerminalAttach.kt`.
//

import Foundation

enum TerminalAttach {
    /// `tmux attach` con target EXACTO (`'=nombre'`): sin '=', tmux cae a coincidencia por
    /// prefijo y, muerta «tmh/web», se engancharía a «tmh/web-admin». `-u`: salida UTF-8
    /// aunque el servidor no fije el locale (Argos no envía LANG por el canal SSH).
    static func command(session name: String) -> String {
        "tmux -u attach -t \(ShellQuoting.singleQuoted("=\(name)"))"
    }
}

/// La sesión tmux a la que se quería enganchar el terminal ya no existe en el servidor
/// (su último proceso terminó o alguien la detuvo). Reintentar no sirve: hay que iniciarla.
struct TerminalSessionMissingError: LocalizedError, Equatable {
    let session: String

    var errorDescription: String? {
        String(localized: "La sesión «\(session)» ya no existe en el servidor.")
    }

    var recoverySuggestion: String? {
        String(localized: "Inicia el proyecto de nuevo para crearla.")
    }
}

/// Lee la salida del PTY ANTES de que tmux tome la pantalla y reconoce sus mensajes de
/// «no hay tal sesión». En cuanto tmux entra en la pantalla alternativa deja de mirar:
/// lo que se imprima dentro de la sesión nunca cuenta.
struct TerminalAttachMonitor: Sendable, Equatable {
    /// Mensajes de tmux (no se traducen) cuando no hay sesión: 2.x+, 1.x y sin servidor.
    static let missingSessionMessages = [
        "can't find session",
        "session not found",
        "no server running",
        "no sessions",
    ]
    /// `smcup` (pantalla alternativa): tmux la activa al engancharse.
    static let attachedSequence = "\u{1B}[?1049h"
    /// Cola que se guarda entre trozos para no perder un mensaje partido en dos.
    private static let tailLength = 64

    private(set) var sawMissingSession = false
    private(set) var isAttached = false
    private var tail = ""

    /// Procesa un trozo de salida del PTY.
    mutating func consume(_ bytes: [UInt8]) {
        guard !isAttached, !sawMissingSession else { return }
        let text = tail + String(decoding: bytes, as: UTF8.self)
        if text.contains(Self.attachedSequence) {
            isAttached = true
            tail = ""
            return
        }
        let lowered = text.lowercased()
        if Self.missingSessionMessages.contains(where: { lowered.contains($0) }) {
            sawMissingSession = true
            tail = ""
            return
        }
        tail = String(text.suffix(Self.tailLength))
    }
}
