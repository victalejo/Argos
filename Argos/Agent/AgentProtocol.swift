//
//  AgentProtocol.swift
//  Argos
//
//  Codec puro del protocolo `stream-json` del CLI `claude`: decodifica líneas NDJSON
//  de stdout a `AgentStreamEvent` y construye los mensajes que se escriben en stdin
//  (prompt del usuario y respuestas de permiso). Sin estado ni dependencias de red/UI:
//  totalmente testeable. Ver memoria `argos-claude-agent-protocol`.
//

import Foundation

/// Decisión del usuario ante una solicitud de permiso de herramienta.
enum AgentPermissionDecision: Sendable, Equatable {
    /// Permite la herramienta, opcionalmente con el input (posiblemente ajustado).
    case allow(updatedInput: JSONValue)
    /// Deniega la herramienta con un mensaje para el modelo.
    case deny(message: String)
}

enum AgentProtocol {

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Claves ordenadas → salida determinista (facilita tests). El orden de las
        // claves es irrelevante para el CLI.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: - Decodificación (stdout → eventos)

    /// Decodifica una línea NDJSON. Devuelve `nil` si la línea está vacía o no es
    /// JSON válido (p. ej. una línea parcial o ruido).
    static func decode(line: String) -> AgentStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let value = try? decoder.decode(JSONValue.self, from: data),
              let object = value.objectValue,
              let type = object["type"]?.stringValue
        else { return nil }

        switch type {
        case "system":
            if object["subtype"]?.stringValue == "init" {
                return .initialized(AgentInit(
                    sessionID: object["session_id"]?.stringValue ?? "",
                    model: object["model"]?.stringValue
                ))
            }
            return .ignored(type: type, subtype: object["subtype"]?.stringValue)

        case "assistant":
            return .assistant(contentBlocks(from: object["message"]))

        case "user":
            return .user(contentBlocks(from: object["message"]))

        case "control_request":
            return controlRequestEvent(object)

        case "control_cancel_request":
            if let requestID = object["request_id"]?.stringValue {
                return .permissionCancel(requestID: requestID)
            }
            return .ignored(type: type, subtype: nil)

        case "result":
            return .result(AgentResult(
                subtype: object["subtype"]?.stringValue ?? "",
                isError: object["is_error"]?.boolValue ?? false,
                text: object["result"]?.stringValue,
                totalCostUSD: doubleValue(object["total_cost_usd"])
            ))

        case "rate_limit_event":
            return .rateLimit

        default:
            return .ignored(type: type, subtype: object["subtype"]?.stringValue)
        }
    }

    private static func controlRequestEvent(_ object: [String: JSONValue]) -> AgentStreamEvent {
        guard let request = object["request"]?.objectValue,
              request["subtype"]?.stringValue == "can_use_tool",
              let requestID = object["request_id"]?.stringValue,
              let toolName = request["tool_name"]?.stringValue
        else {
            return .ignored(type: "control_request", subtype: object["request"]?["subtype"]?.stringValue)
        }
        return .permissionRequest(AgentPermissionRequest(
            id: requestID,
            toolName: toolName,
            displayName: request["display_name"]?.stringValue,
            input: request["input"] ?? .object([:]),
            toolUseID: request["tool_use_id"]?.stringValue
        ))
    }

    /// Extrae los bloques de contenido de un `message` cuyo `content` puede ser una
    /// cadena (texto plano) o un array de bloques tipados.
    private static func contentBlocks(from message: JSONValue?) -> [AgentContentBlock] {
        guard let content = message?["content"] else { return [] }

        if let text = content.stringValue {
            return text.isEmpty ? [] : [.text(text)]
        }

        guard let items = content.arrayValue else { return [] }
        return items.compactMap(block(from:))
    }

    private static func block(from item: JSONValue) -> AgentContentBlock? {
        guard let object = item.objectValue,
              let type = object["type"]?.stringValue else { return nil }

        switch type {
        case "text":
            return .text(object["text"]?.stringValue ?? "")
        case "thinking":
            return .thinking(object["thinking"]?.stringValue ?? "")
        case "tool_use":
            guard let id = object["id"]?.stringValue,
                  let name = object["name"]?.stringValue else { return nil }
            return .toolUse(id: id, name: name, input: object["input"] ?? .object([:]))
        case "tool_result":
            guard let toolUseID = object["tool_use_id"]?.stringValue else { return nil }
            return .toolResult(
                toolUseID: toolUseID,
                text: flattenedText(object["content"]),
                isError: object["is_error"]?.boolValue ?? false
            )
        default:
            return nil
        }
    }

    /// Aplana el `content` de un tool_result (string o array de bloques de texto) a texto.
    private static func flattenedText(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let text = value.stringValue { return text }
        guard let items = value.arrayValue else { return "" }
        return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    private static func doubleValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }

    // MARK: - Codificación (app → stdin)

    /// Construye la línea NDJSON de un mensaje de usuario (prompt).
    static func encodeUserMessage(text: String) -> String {
        encodeLine(.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .string(text)
            ])
        ]))
    }

    /// Construye la línea NDJSON de la respuesta a una solicitud de permiso.
    static func encodePermissionResponse(
        requestID: String,
        decision: AgentPermissionDecision
    ) -> String {
        let inner: JSONValue
        switch decision {
        case .allow(let updatedInput):
            inner = .object(["behavior": .string("allow"), "updatedInput": updatedInput])
        case .deny(let message):
            inner = .object(["behavior": .string("deny"), "message": .string(message)])
        }
        return encodeLine(.object([
            "type": .string("control_response"),
            "response": .object([
                "subtype": .string("success"),
                "request_id": .string(requestID),
                "response": inner
            ])
        ]))
    }

    private static func encodeLine(_ value: JSONValue) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }
}

/// Acumula bytes de stdout y los parte en líneas completas (NDJSON). Mantiene el
/// resto incompleto entre llamadas. Puro y testeable.
struct NDJSONLineBuffer {
    private var buffer = Data()

    /// Añade un chunk de bytes y devuelve las líneas completas disponibles.
    mutating func append(_ bytes: [UInt8]) -> [String] {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }
}
