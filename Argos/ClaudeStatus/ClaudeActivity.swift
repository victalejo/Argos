//
//  ClaudeActivity.swift
//  Argos
//
//  Estado de Claude Code dentro de los paneles de tmux (lógica pura). Los hooks de
//  Claude Code instalados por `ClaudeHookInstaller` escriben la opción de panel
//  `@argos_claude` (working / waiting / done); Argos la lee con:
//      tmux list-panes -a -F '#{@argos_claude}|#{window_index}|#{session_name}'
//  El nombre de sesión va AL FINAL para tolerar '|' dentro de él.
//

import Foundation

/// Qué está haciendo Claude Code en un panel.
enum ClaudeActivity: String, Sendable, CaseIterable {
    /// Procesando (tras un prompt o una herramienta).
    case working
    /// Necesita al usuario: permiso, pregunta o diálogo.
    case waiting
    /// Terminó de responder; espera el siguiente prompt.
    case done

    /// Para agregar varios paneles: lo que requiere atención gana.
    var priority: Int {
        switch self {
        case .waiting: return 3
        case .done: return 2
        case .working: return 1
        }
    }

    var label: String {
        switch self {
        case .working: return "Claude trabajando"
        case .waiting: return "Claude espera tu respuesta"
        case .done: return "Claude terminó"
        }
    }
}

/// Paso a un estado que merece aviso (esperando o terminó) en una sesión.
struct ClaudeTransition: Equatable, Sendable {
    let session: String
    let activity: ClaudeActivity
}

/// Estado de Claude en todas las sesiones de un servidor, agregado por sesión y ventana.
struct ClaudeActivitySnapshot: Equatable, Sendable {
    /// sesión -> índice de ventana -> estado (agregado si hay varios paneles).
    private let bySession: [String: [Int: ClaudeActivity]]

    static let empty = ClaudeActivitySnapshot(bySession: [:])

    private init(bySession: [String: [Int: ClaudeActivity]]) {
        self.bySession = bySession
    }

    /// Parsea la salida de `list-panes` (ver cabecera). Ignora paneles sin estado o
    /// con valores desconocidos.
    init(listPanesOutput: String) {
        var result: [String: [Int: ClaudeActivity]] = [:]
        for line in listPanesOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let activity = ClaudeActivity(rawValue: String(fields[0])),
                  let window = Int(fields[1]),
                  !fields[2].isEmpty
            else { continue }
            let session = String(fields[2])
            let current = result[session]?[window]
            if current.map({ activity.priority > $0.priority }) ?? true {
                result[session, default: [:]][window] = activity
            }
        }
        self.bySession = result
    }

    /// Estado agregado de la sesión (el de mayor prioridad entre sus ventanas).
    func activity(forSession session: String) -> ClaudeActivity? {
        bySession[session]?.values.max { $0.priority < $1.priority }
    }

    /// Estado por índice de ventana de la sesión.
    func windows(forSession session: String) -> [Int: ClaudeActivity] {
        bySession[session] ?? [:]
    }

    /// Sesiones que ENTRARON en "esperando" o "terminó" respecto a `previous`.
    func notableTransitions(since previous: ClaudeActivitySnapshot) -> [ClaudeTransition] {
        bySession.keys.sorted().compactMap { session in
            guard let now = activity(forSession: session),
                  now == .waiting || now == .done,
                  previous.activity(forSession: session) != now
            else { return nil }
            return ClaudeTransition(session: session, activity: now)
        }
    }
}
