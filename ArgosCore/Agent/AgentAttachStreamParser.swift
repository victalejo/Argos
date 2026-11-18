//
//  AgentAttachStreamParser.swift
//  Argos
//
//  Clasifica las líneas que llegan al engancharse al log de un agente persistente
//  (lógica pura):
//   - antes de la cabecera `argos_log_base`, lo que no es JSON es ruido del perfil del
//     shell (un `.bashrc` que imprime algo) y NO cuenta como bytes del log;
//   - sin cabecera (mock, servidor raro), la primera línea JSON empieza los datos;
//   - `argos_log_rotated` avisa de que el log va a sustituirse: lo que venga después en
//     ese enganche es la copia conservada y se ignora (el cliente se reengancha). Sus
//     bytes no cuentan en los desplazamientos absolutos.
//

import Foundation

struct AgentAttachStreamParser {
    enum Line: Equatable {
        case noise
        case header(base: Int, from: Int)
        case data
        case rotated
    }

    /// Espera antes de reengancharse tras una rotación (que termine de sustituir el log).
    static let rotationSettleDelay: Duration = .milliseconds(500)

    private enum Phase { case awaitingHeader, data, rotated }
    private var phase = Phase.awaitingHeader

    mutating func classify(text: String?) -> Line {
        switch phase {
        case .rotated:
            return .noise
        case .awaitingHeader:
            guard let text else { return .noise }
            if let header = PersistentAgentScript.parseLogBase(text) {
                phase = .data
                return .header(base: header.base, from: header.from)
            }
            guard Self.isJSONObject(text) else { return .noise }
            phase = .data
            return classifyData(text)
        case .data:
            return classifyData(text)
        }
    }

    private mutating func classifyData(_ text: String?) -> Line {
        guard let text, Self.isRotationMarker(text) else { return .data }
        phase = .rotated
        return .rotated
    }

    static func isRotationMarker(_ text: String) -> Bool {
        text.contains(PersistentAgentShell.rotatedEventType)
            && AgentProtocol.decode(line: text) == .ignored(type: PersistentAgentShell.rotatedEventType, subtype: nil)
    }

    private static func isJSONObject(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
}
