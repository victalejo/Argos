//
//  JSONValue.swift
//  Argos
//
//  Valor JSON arbitrario, `Sendable` y `Codable`. Lo usa el panel de agente para
//  transportar el `input` de las herramientas de Claude Code (cuyo esquema es
//  dinámico) entre el protocolo stream-json y la UI, sin perder fidelidad y sin
//  acoplarse a un tipo concreto.
//
//  Preserva enteros vs. decimales (`.int` / `.double`) porque los inputs de
//  herramientas a veces dependen de ello (índices de línea, offsets…).
//

import Foundation

/// Un valor JSON genérico (null, bool, número, string, array u objeto).
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Valor JSON no reconocido."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Accesos convenientes (lectura tolerante)

extension JSONValue {
    /// El diccionario subyacente si es un objeto.
    var objectValue: [String: JSONValue]? {
        if case .object(let dictionary) = self { return dictionary }
        return nil
    }

    /// El array subyacente si es un array.
    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// El texto subyacente si es una cadena.
    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// El booleano subyacente si es un bool.
    var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// Acceso por clave en un objeto (`nil` si no es objeto o no existe la clave).
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
