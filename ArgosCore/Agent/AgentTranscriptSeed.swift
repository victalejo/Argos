//
//  AgentTranscriptSeed.swift
//  Argos
//
//  «Continuar en el servidor»: una conversación del panel del Mac pasa a ser un agente
//  persistente con el MISMO id de sesión (`claude --resume`). `--resume` no repite la
//  conversación, así que su log (`out.ndjson`) empieza con lo que ya se veía, escrito como
//  los eventos stream-json que el propio claude emite. Cualquier cliente (Mac, iPhone,
//  Android, versiones publicadas) reconstruye así la conversación al engancharse, sin
//  cambiar el formato del servidor. Lógica pura y testeable.
//

import Foundation

enum AgentTranscriptSeed {

    /// Tope del log inicial: lo que no cabe se omite empezando por lo más antiguo.
    static let maxBytes = 8 * 1_048_576
    /// `subtype` del `result` que cierra el log inicial si la conversación no acababa en
    /// uno: sin él, al releerlo parecería que Claude sigue trabajando y el vigilante del
    /// servidor nunca lo vería quieto.
    static let closingSubtype = "argos_seed"

    struct Seed: Equatable, Sendable {
        /// Líneas NDJSON (sin el salto final).
        let lines: [String]
        /// Lo que se escribe en el log: cada línea con su `\n`.
        var bytes: [UInt8] { Array(lines.map { $0 + "\n" }.joined().utf8) }
        /// La conversación tal como la reconstruye un cliente al leer el log.
        var replayedState: AgentConversationState {
            var state = AgentConversationState()
            for line in lines {
                guard let event = AgentProtocol.decode(line: line) else { continue }
                AgentReducer.apply(event, to: &state, echoesUserMessages: true)
            }
            return state
        }
    }

    /// Log inicial con la conversación de `state` (los errores de la conexión anterior no
    /// se copian: eran de aquel proceso).
    static func make(from state: AgentConversationState, maxBytes: Int = maxBytes) -> Seed {
        var lines: [String] = []
        for (index, item) in state.items.enumerated() {
            if let line = line(for: item.kind, index: index) { lines.append(line) }
        }
        if !lines.isEmpty, !endsWithResult(lines) {
            lines.append(encode(.object([
                "type": .string("result"), "subtype": .string(closingSubtype), "is_error": .bool(false),
            ])))
        }
        return Seed(lines: trimmed(lines, maxBytes: maxBytes))
    }

    private static func endsWithResult(_ lines: [String]) -> Bool {
        guard let last = lines.last, let event = AgentProtocol.decode(line: last) else { return false }
        if case .result = event { return true }
        return false
    }

    /// Conserva las líneas más recientes que caben en `maxBytes` (nunca empieza a medias:
    /// si sobra una respuesta de herramienta sin su llamada, solo se ve el resultado).
    private static func trimmed(_ lines: [String], maxBytes: Int) -> [String] {
        var total = 0
        var kept: [String] = []
        for line in lines.reversed() {
            let size = line.utf8.count + 1
            guard total + size <= maxBytes else { break }
            total += size
            kept.append(line)
        }
        return kept.reversed()
    }

    static func line(for kind: AgentTranscriptItem.Kind, index: Int) -> String? {
        let toolID = "argos-seed-\(index)"
        switch kind {
        case .userText(let text):
            return message("user", content: .string(text))
        case .assistantText(let text):
            return message("assistant", content: .array([.object(["type": .string("text"), "text": .string(text)])]))
        case .thinking(let text):
            return message("assistant", content: .array([.object(["type": .string("thinking"), "thinking": .string(text)])]))
        case .toolUse(let name, let input):
            return message("assistant", content: .array([.object([
                "type": .string("tool_use"), "id": .string(toolID), "name": .string(name), "input": input,
            ])]))
        case .toolResult(let text, let isError):
            return message("user", content: .array([.object([
                "type": .string("tool_result"), "tool_use_id": .string(toolID),
                "content": .string(text), "is_error": .bool(isError),
            ])]))
        case .result(let result):
            var object: [String: JSONValue] = [
                "type": .string("result"), "subtype": .string(result.subtype), "is_error": .bool(result.isError),
            ]
            if let text = result.text { object["result"] = .string(text) }
            if let cost = result.totalCostUSD { object["total_cost_usd"] = .double(cost) }
            return encode(.object(object))
        case .error:
            return nil
        }
    }

    private static func message(_ role: String, content: JSONValue) -> String {
        encode(.object([
            "type": .string(role),
            "message": .object(["role": .string(role), "content": content]),
        ]))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func encode(_ value: JSONValue) -> String {
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Script del servidor

extension PersistentAgentScript {

    static let seededReply = "ARGOS_SEEDED"
    static let existsReply = "ARGOS_AGENT_EXISTS"

    /// Crea la carpeta de un agente NUEVO con id `id` y escribe en su `out.ndjson` los
    /// `byteCount` bytes que llegan por stdin (el log inicial de `AgentTranscriptSeed`). La
    /// carpeta se crea con `mkdir` (atómico): si ya hay un agente con ese id no se toca y
    /// responde `ARGOS_AGENT_EXISTS`. Una carpeta a medias (sin `meta.json`, de un intento
    /// anterior interrumpido) se descarta antes. Responde `ARGOS_SEEDED` o
    /// `ARGOS_SEND_SHORT` (no llegó entero: no queda nada).
    static func seed(id: String, byteCount: Int) -> String {
        let dir = directory(id)
        return [
            "mkdir -p \"$HOME/\(rootRelativePath)\" && chmod 700 \"$HOME/\(rootRelativePath)\" || exit 1",
            "if [ -d \(dir) ] && [ ! -f \(dir)/meta.json ] && ! \(aliveCheck(id)); then rm -rf \(dir); fi",
            "( umask 077 && mkdir \(dir) ) 2>/dev/null || { echo \(existsReply); exit 5; }",
            "( umask 077 && head -c \(max(0, byteCount)) > \(dir)/out.ndjson )",
            "n=$(wc -c < \(dir)/out.ndjson | tr -d ' ')",
            "if [ \"$n\" != \"\(max(0, byteCount))\" ]; then rm -rf \(dir); echo \(shortReply); exit 7; fi",
            "echo \(seededReply)",
        ].joined(separator: "\n")
    }
}

/// Errores al pasar una conversación al servidor.
enum AgentConversionError: LocalizedError, Equatable {
    /// No hay conversación que continuar (ningún mensaje enviado).
    case nothingToContinue
    /// Claude está trabajando o espera un permiso.
    case busy
    /// Ya existe en el servidor un agente persistente con esa conversación.
    case alreadyPersistent

    var errorDescription: String? {
        switch self {
        case .nothingToContinue:
            return "Esta conversación aún no tiene mensajes: abre una conversación nueva en el servidor."
        case .busy:
            return "Claude está trabajando o espera un permiso. Espera a que termine o detén el turno y vuelve a intentarlo."
        case .alreadyPersistent:
            return "Esta conversación ya sigue en el servidor. Ábrela desde «En el servidor»."
        }
    }
}
