//
//  AgentConversationState.swift
//  Argos
//
//  Estado de la conversación del agente y su reducer PURO (evento → nuevo estado).
//  Separar la reducción de la red/UI la hace determinista y testeable: los ids de
//  los items son enteros incrementales (no UUID), así dos reducciones idénticas son
//  comparables por igualdad.
//

import Foundation

/// Estado de la conexión/turno del agente, para el feedback de la UI.
enum AgentStatus: Equatable, Sendable {
    /// Lanzando el proceso remoto, antes del `init`.
    case connecting
    /// Listo para recibir un prompt del usuario.
    case idle
    /// Turno en curso (el modelo está trabajando).
    case working
    /// El proceso remoto terminó (EOF) de forma normal.
    case finished
    /// Fallo de transporte o del proceso.
    case failed(String)
}

/// Un elemento renderizable del transcript. `id` entero para identidad estable y
/// determinista.
struct AgentTranscriptItem: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case userText(String)
        case assistantText(String)
        case thinking(String)
        case toolUse(name: String, input: JSONValue)
        case toolResult(text: String, isError: Bool)
        case result(AgentResult)
        case error(String)
    }
}

/// Estado completo de una conversación de agente.
struct AgentConversationState: Equatable, Sendable {
    private(set) var items: [AgentTranscriptItem] = []
    var status: AgentStatus = .connecting
    var pendingPermission: AgentPermissionRequest?
    var sessionID: String?

    /// Contador para ids deterministas de los items.
    private var counter: Int = 0

    /// Añade un item al transcript con id estable.
    mutating func append(_ kind: AgentTranscriptItem.Kind) {
        items.append(AgentTranscriptItem(id: counter, kind: kind))
        counter += 1
    }
}

/// Reductor puro: aplica un evento del CLI (o una acción del usuario) al estado.
enum AgentReducer {

    /// Aplica un evento decodificado del stream-json.
    static func apply(_ event: AgentStreamEvent, to state: inout AgentConversationState) {
        switch event {
        case .initialized(let info):
            state.sessionID = info.sessionID
            if state.status == .connecting { state.status = .idle }

        case .assistant(let blocks):
            blocks.forEach { appendBlock($0, to: &state) }

        case .user(let blocks):
            for block in blocks {
                if case .toolResult(_, let text, let isError) = block {
                    state.append(.toolResult(text: text, isError: isError))
                }
            }

        case .permissionRequest(let request):
            state.pendingPermission = request

        case .permissionCancel(let requestID):
            if state.pendingPermission?.id == requestID {
                state.pendingPermission = nil
            }

        case .result(let result):
            state.append(.result(result))
            state.status = .idle

        case .rateLimit, .ignored:
            break
        }
    }

    /// Registra el envío de un prompt del usuario (cambia a "trabajando").
    static func userSent(text: String, to state: inout AgentConversationState) {
        state.append(.userText(text))
        state.status = .working
    }

    /// Marca el fin de la conexión (EOF o error de transporte).
    static func finished(error: String?, to state: inout AgentConversationState) {
        state.pendingPermission = nil
        if let error {
            state.append(.error(error))
            state.status = .failed(error)
        } else {
            state.status = .finished
        }
    }

    private static func appendBlock(
        _ block: AgentContentBlock,
        to state: inout AgentConversationState
    ) {
        switch block {
        case .text(let text):
            if !text.isEmpty { state.append(.assistantText(text)) }
        case .thinking(let text):
            if !text.isEmpty { state.append(.thinking(text)) }
        case .toolUse(_, let name, let input):
            state.append(.toolUse(name: name, input: input))
        case .toolResult(_, let text, let isError):
            state.append(.toolResult(text: text, isError: isError))
        }
    }
}
