//
//  AgentToolSummary.swift
//  Argos
//
//  Resumen corto (puro, testeable) del `input` de una herramienta para mostrarlo
//  junto a su nombre en el transcript y en la tarjeta de permiso.
//

import Foundation

enum AgentToolSummary {

    /// Devuelve un resumen de una línea del input de la herramienta `name`.
    static func summary(name: String, input: JSONValue) -> String {
        switch name {
        case "Bash":
            return input["command"]?.stringValue ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return input["file_path"]?.stringValue
                ?? input["notebook_path"]?.stringValue ?? ""
        case "Glob", "Grep":
            return input["pattern"]?.stringValue ?? ""
        case "WebFetch":
            return input["url"]?.stringValue ?? ""
        case "WebSearch":
            return input["query"]?.stringValue ?? ""
        default:
            return input["command"]?.stringValue
                ?? input["file_path"]?.stringValue
                ?? input["pattern"]?.stringValue
                ?? input["description"]?.stringValue
                ?? ""
        }
    }
}
