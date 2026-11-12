//
//  ClaudeActivity.swift
//  Argos
//
//  Estado de Claude Code dentro de los paneles de tmux (lógica pura). Los hooks de
//  Claude Code instalados por `ClaudeHookInstaller` escriben la opción de panel
//  `@argos_claude` (working / waiting / done); Argos la lee con un `list-panes -a`
//  (ver `ClaudeScreenProbe`), una línea por panel:
//      <pantalla>|<estado>|<pane_id>|<window_index>|<session_name>
//  El nombre de sesión va AL FINAL para tolerar '|' dentro de él.
//
//  Los hooks no cubren todo: interrumpir con Esc NO dispara `Stop` (el panel se
//  quedaría «trabajando» para siempre) y tras aprobar un permiso no hay evento hasta
//  que la herramienta acaba (se quedaría «esperando» mientras corre). Por eso se
//  corrige con lo que muestra la pantalla del panel (`ClaudeScreenSignal`).
//

import Foundation

/// Qué está haciendo Claude Code en un panel.
enum ClaudeActivity: String, Sendable, CaseIterable, Codable {
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

/// Lo que se ve en la pantalla del panel (solo se mira en paneles working/waiting).
enum ClaudeScreenSignal: String, Sendable {
    /// No se miró la pantalla.
    case unchecked = "-"
    /// Ni spinner ni pie de «esc to interrupt»: Claude está parado.
    case idle = "0"
    /// Línea del spinner (`✻ Pensando… (12s · …)`) en algún sitio: señal débil.
    case spinner = "1"
    /// «esc to interrupt» en el pie (últimas líneas): seguro que está trabajando.
    case busy = "2"
}

/// Paso a un estado que merece aviso (esperando o terminó) en una ventana.
struct ClaudeTransition: Equatable, Sendable {
    let session: String
    let window: Int
    let activity: ClaudeActivity
}

/// Estado de Claude en un panel, ya corregido con la pantalla.
struct ClaudePaneActivity: Equatable, Sendable, Codable {
    let paneID: String
    let session: String
    let window: Int
    let activity: ClaudeActivity
    /// Llegó a `done` porque se interrumpió (o Claude murió sin `SessionEnd`): no se avisa.
    let isQuiet: Bool

    /// Corrige el estado de los hooks con la pantalla:
    /// - `working` sin rastro de trabajo -> interrumpido: `done` silencioso.
    /// - `waiting` con «esc to interrupt» en el pie -> ya se respondió y está trabajando.
    static func resolve(hook: ClaudeActivity, screen: ClaudeScreenSignal) -> (ClaudeActivity, quiet: Bool) {
        switch (hook, screen) {
        case (.working, .idle): return (.done, true)
        case (.waiting, .busy): return (.working, false)
        default: return (hook, false)
        }
    }
}

/// Estado de Claude en todas las sesiones de un servidor.
struct ClaudeActivitySnapshot: Equatable, Sendable, Codable {
    /// Un elemento por panel con estado, en el orden de `list-panes`.
    let panes: [ClaudePaneActivity]

    static let empty = ClaudeActivitySnapshot(panes: [])

    init(panes: [ClaudePaneActivity]) {
        self.panes = panes
    }

    /// Parsea la salida del sondeo (ver cabecera). Ignora paneles sin estado o con
    /// valores desconocidos.
    init(listPanesOutput: String) {
        self.panes = listPanesOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5,
                  let hook = ClaudeActivity(rawValue: String(fields[1])),
                  !fields[2].isEmpty,
                  let window = Int(fields[3]),
                  !fields[4].isEmpty
            else { return nil }
            let screen = ClaudeScreenSignal(rawValue: String(fields[0])) ?? .unchecked
            let resolved = ClaudePaneActivity.resolve(hook: hook, screen: screen)
            return ClaudePaneActivity(
                paneID: String(fields[2]), session: String(fields[4]), window: window,
                activity: resolved.0, isQuiet: resolved.quiet
            )
        }
    }

    /// Estado agregado de la sesión (el de mayor prioridad entre sus paneles).
    func activity(forSession session: String) -> ClaudeActivity? {
        Self.mostUrgent(panes.lazy.filter { $0.session == session }.map(\.activity))
    }

    /// Estado más urgente entre varias sesiones (p. ej. un grupo colapsado).
    func activity(forSessions sessions: [String]) -> ClaudeActivity? {
        let wanted = Set(sessions)
        return Self.mostUrgent(panes.lazy.filter { wanted.contains($0.session) }.map(\.activity))
    }

    /// Estado por índice de ventana de la sesión (agregado si hay varios paneles).
    func windows(forSession session: String) -> [Int: ClaudeActivity] {
        var result: [Int: ClaudeActivity] = [:]
        for pane in panes where pane.session == session {
            if result[pane.window].map({ pane.activity.priority > $0.priority }) ?? true {
                result[pane.window] = pane.activity
            }
        }
        return result
    }

    /// Paneles que ENTRARON en "esperando" o "terminó" respecto a `previous`. Se mira
    /// PANEL a panel: que otra ventana de la sesión ya esté esperando/terminada no
    /// oculta el aviso de esta. Lo silencioso (interrupción) no se avisa.
    func notableTransitions(since previous: ClaudeActivitySnapshot) -> [ClaudeTransition] {
        let before = Dictionary(previous.panes.map { ($0.paneID, $0.activity) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return panes.compactMap { pane in
            guard !pane.isQuiet,
                  pane.activity == .waiting || pane.activity == .done,
                  before[pane.paneID] != pane.activity
            else { return nil }
            // Dos paneles de la misma ventana: un solo aviso.
            guard seen.insert("\(pane.session)\u{0}\(pane.window)").inserted else { return nil }
            return ClaudeTransition(session: pane.session, window: pane.window, activity: pane.activity)
        }
    }

    private static func mostUrgent<S: Sequence>(_ activities: S) -> ClaudeActivity? where S.Element == ClaudeActivity {
        activities.max { $0.priority < $1.priority }
    }
}
