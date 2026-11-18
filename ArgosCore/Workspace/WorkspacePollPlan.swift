//
//  WorkspacePollPlan.swift
//  ArgosCore
//
//  Planificación del sondeador (lógica pura): cada cuánto se sondea según lo que hace la
//  app, cuándo toca la siguiente vuelta y qué tareas hay que arrancar o parar para seguir
//  la lista viva de servidores.
//

import Foundation

/// Lo que está haciendo la app (lo calcula cada plataforma).
enum WorkspaceActivity: Sendable, Equatable {
    /// En primer plano con la ventana a la vista.
    case active
    /// Abierta pero otra app está delante.
    case inactive
    /// Ventana tapada (otra app a pantalla completa), minimizada o la app oculta: lo
    /// habitual con Argos detrás; los avisos deben seguir llegando enseguida.
    case hidden
    /// Sin ventana (cerrada): la app solo vive para avisar.
    case windowClosed
    /// El equipo duerme: no se abre ninguna conexión.
    case asleep
}

/// Intervalos del sondeo. `tick` es cada cuánto se comprueba si toca vuelta (sin red).
struct WorkspacePollTiming: Sendable, Equatable {
    var active: Duration
    var inactive: Duration
    var hidden: Duration
    var windowClosed: Duration
    var tick: Duration

    /// 3 s delante (como antes el estado de Claude), 5 s detrás o tapada y 20 s solo con
    /// la ventana cerrada.
    static let standard = WorkspacePollTiming(
        active: .seconds(3), inactive: .seconds(5), hidden: .seconds(5), windowClosed: .seconds(20),
        tick: .milliseconds(500)
    )

    /// Intervalo entre vueltas; `nil` = en pausa.
    func interval(for activity: WorkspaceActivity) -> Duration? {
        switch activity {
        case .active: return active
        case .inactive: return inactive
        case .hidden: return hidden
        case .windowClosed: return windowClosed
        case .asleep: return nil
        }
    }
}

enum WorkspacePollPlan {

    /// ¿Toca vuelta? La primera siempre (salvo en reposo); un empujón (`nudged`: la app
    /// vuelve delante, el equipo despierta) la adelanta.
    static func isDue(
        lastRound: ContinuousClock.Instant?,
        now: ContinuousClock.Instant,
        activity: WorkspaceActivity,
        nudged: Bool,
        timing: WorkspacePollTiming
    ) -> Bool {
        guard let interval = timing.interval(for: activity) else { return false }
        guard let lastRound, !nudged else { return true }
        return now - lastRound >= interval
    }

    /// Qué se pide en cada vuelta: todo junto, porque va en un solo comando.
    static let sections: Set<WorkspacePollSection> = Set(WorkspacePollSection.allCases)

    /// Tareas que hay que parar y servidores que hay que arrancar para que haya
    /// exactamente una por servidor y con su view model actual (`token` lo identifica: un
    /// servidor editado con conexión nueva cambia de view model y su tarea se rehace).
    static func reconcile<ID: Hashable, Token: Hashable>(
        running: [ID: Token],
        wanted: [ID: Token]
    ) -> (stop: Set<ID>, start: Set<ID>) {
        let stop = Set(running.compactMap { id, token in wanted[id] == token ? nil : id })
        let start = Set(wanted.compactMap { id, token in running[id] == token ? nil : id })
        return (stop, start)
    }
}

/// De qué sesión NO se avisa porque el usuario la está mirando (lógica pura): solo con la
/// app delante y la ventana a la vista. La selección sobrevive a cerrar la ventana, así que
/// sin esta condición se silenciaban los avisos de la última sesión elegida.
enum NoticeViewing {
    static func viewingSession(selected: SessionHandle?, serverID: Server.ID, activity: WorkspaceActivity) -> String? {
        guard activity == .active, let selected, selected.serverID == serverID else { return nil }
        return selected.sessionID
    }
}
