//
//  AgentConversationDriving.swift
//  Argos
//
//  Lo común a las dos clases de conversación con Claude Code, para que UNA vista las
//  pinte y las maneje igual:
//   - `ClaudeAgentSession`: conversación «de esta sesión» (panel Agente del Mac). Su
//     `claude` vive mientras dura el canal SSH: cerrarla o salir de Argos lo detiene.
//   - `PersistentAgentSession`: agente persistente. Su `claude` corre en el servidor
//     (FIFO + log); la app solo se engancha. Cerrar la pestaña no lo detiene.
//
//  La fase de la conversación se decide con lógica pura (`AgentConversationPhase`).
//

import Foundation

/// De quién depende la vida del proceso de `claude`.
enum AgentConversationLifecycle: Equatable, Sendable {
    /// Vive con la conexión de esta app (se detiene al cerrar la pestaña o salir).
    case session
    /// Vive en el servidor (sigue aunque se cierre Argos o se corte la red).
    case persistent
}

/// En qué punto está la conversación, para la barra de entrada y los avisos.
enum AgentConversationPhase: Equatable, Sendable {
    /// Lista para un mensaje.
    case ready
    /// Claude trabaja en un turno.
    case working
    /// Claude espera que se permita o deniegue una herramienta.
    case awaitingPermission
    /// Persistente en reposo: escribirle lo reanuda.
    case asleep
    /// Arrancando de nuevo el proceso (`--resume`).
    case resuming
    /// El proceso no está en marcha.
    case stopped(StopReason)

    enum StopReason: Equatable, Sendable {
        /// La conversación terminó con normalidad (o con un error del proceso).
        case ended
        /// Se perdió la conexión con el servidor (conversación de esta sesión).
        case connectionLost
        /// El agente persistente está detenido en el servidor.
        case agentStopped
    }

    /// Se puede escribir y enviar (en reposo, enviar lo reanuda).
    var acceptsMessages: Bool {
        switch self {
        case .ready, .asleep: return true
        case .working, .awaitingPermission, .resuming, .stopped: return false
        }
    }

    /// Hay un turno en curso o un permiso pendiente.
    var isBusy: Bool {
        self == .working || self == .awaitingPermission
    }

    var isStopped: Bool {
        if case .stopped = self { return true }
        return false
    }

    /// Fase de una conversación de esta sesión (panel del Mac).
    static func session(status: AgentStatus, hasPendingPermission: Bool, lostConnection: Bool) -> Self {
        switch status {
        case .finished, .failed: return .stopped(lostConnection ? .connectionLost : .ended)
        case .working, .connecting: return hasPendingPermission ? .awaitingPermission : .working
        case .idle: return hasPendingPermission ? .awaitingPermission : .ready
        }
    }

    /// Fase de un agente persistente.
    static func persistent(
        isAlive: Bool,
        isHibernated: Bool,
        isResuming: Bool,
        status: AgentStatus,
        hasPendingPermission: Bool
    ) -> Self {
        if isResuming { return .resuming }
        guard isAlive else { return isHibernated ? .asleep : .stopped(.agentStopped) }
        if hasPendingPermission { return .awaitingPermission }
        switch status {
        case .working, .connecting: return .working
        case .idle, .finished, .failed: return .ready
        }
    }
}

/// Aviso sobre la conexión al log de un agente persistente (`nil` si está en vivo).
enum AgentConnectionNotice: Equatable, Sendable {
    case connecting
    case reconnecting(attempt: Int)

    var text: String {
        switch self {
        case .connecting: return String(localized: "Conectando con el agente en el servidor…")
        case .reconnecting(let attempt):
            return attempt > 1 ? String(localized: "Sin conexión con el servidor. Reintentando (\(attempt))…") : String(localized: "Reconectando con el servidor…")
        }
    }

    static func from(_ link: AgentLinkState) -> AgentConnectionNotice? {
        switch link {
        case .live, .detached: return nil
        case .connecting: return .connecting
        case .reconnecting(let attempt): return .reconnecting(attempt: attempt)
        }
    }
}

/// Lo que la vista de conversación necesita de una sesión, sea de esta sesión o
/// persistente.
@MainActor
protocol AgentConversationDriving: AnyObject {
    var state: AgentConversationState { get }
    var workingDirectory: String { get }
    var lifecycle: AgentConversationLifecycle { get }
    var phase: AgentConversationPhase { get }
    var connectionNotice: AgentConnectionNotice? { get }
    var isInterrupting: Bool { get }
    /// Último error de una acción (enviar, reanudar…), para mostrarlo.
    var lastError: String? { get }
    /// Modo de permisos que el usuario debe confirmar antes de reanudar (`nil` si no hace falta).
    var resumeConfirmationMode: ClaudeAgentCommand.PermissionMode? { get }

    /// Envía un mensaje. El borrador solo debe vaciarse con `.sent`.
    func submit(_ text: String, confirmedResume: Bool) async -> AgentSendOutcome
    func allowPendingPermission() async
    func denyPendingPermission() async
    /// «Detener» el turno en curso (la conversación sigue abierta).
    func interruptTurn() async
}

// MARK: - Conversación de esta sesión

extension ClaudeAgentSession: AgentConversationDriving {
    var lifecycle: AgentConversationLifecycle { .session }

    var phase: AgentConversationPhase {
        .session(status: state.status, hasPendingPermission: state.pendingPermission != nil, lostConnection: lostConnection)
    }

    var connectionNotice: AgentConnectionNotice? { nil }
    var lastError: String? { nil }
    var resumeConfirmationMode: ClaudeAgentCommand.PermissionMode? { nil }

    func submit(_ text: String, confirmedResume: Bool) async -> AgentSendOutcome {
        guard phase.acceptsMessages, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed }
        sendUserText(text)
        return .sent
    }

    func interruptTurn() async {
        interrupt()
    }
}

// MARK: - Agente persistente

extension PersistentAgentSession: AgentConversationDriving {
    var workingDirectory: String { meta.workingDirectory }
    var lifecycle: AgentConversationLifecycle { .persistent }

    var phase: AgentConversationPhase {
        .persistent(
            isAlive: isAlive, isHibernated: meta.isHibernated, isResuming: isResuming,
            status: state.status, hasPendingPermission: state.pendingPermission != nil
        )
    }

    var connectionNotice: AgentConnectionNotice? {
        isAttached ? AgentConnectionNotice.from(link) : nil
    }

    var resumeConfirmationMode: ClaudeAgentCommand.PermissionMode? {
        meta.resumeRequiresConfirmation ? meta.resolvedPermissionMode : nil
    }

    /// Cada envío es una acción explícita: levanta antes el bloqueo de conexión.
    func submit(_ text: String, confirmedResume: Bool) async -> AgentSendOutcome {
        await liftConnectionBlock()
        return await send(text, confirmedResume: confirmedResume)
    }

    func interruptTurn() async {
        await liftConnectionBlock()
        await interrupt()
    }
}

/// ¿Qué hacer al cerrar la pestaña de una conversación? (lógica pura)
enum AgentTabClosePolicy: Equatable, Sendable {
    /// Solo dejar de mirar: el agente sigue en el servidor.
    case detach
    /// Cerrar y detener su `claude` (no había nada en curso).
    case stop
    /// Cerrar detendría algo en curso: hay que confirmarlo.
    case confirmStop

    static func decide(lifecycle: AgentConversationLifecycle, isBusy: Bool) -> AgentTabClosePolicy {
        switch lifecycle {
        case .persistent: return .detach
        case .session: return isBusy ? .confirmStop : .stop
        }
    }
}
