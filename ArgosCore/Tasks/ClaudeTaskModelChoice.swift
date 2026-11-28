//
//  ClaudeTaskModelChoice.swift
//  ArgosCore
//
//  Modelo y esfuerzo de un encargo, de una tarea programada o de una plantilla («Haiku para
//  actualizar dependencias, Opus para rediseñar»). Lógica pura y lista CERRADA: estos valores
//  acaban en la línea de `claude` (`--model`, `--effort`) o se escriben en la terminal
//  (`/model`, `/effort`), así que nunca se acepta texto libre. Se usan los alias del CLI
//  (`haiku`, `sonnet`, `opus`) para no atarse a una versión concreta del modelo.
//
//  Guardado aditivo: en `meta` y en la `config` de las programadas son las claves `model=` y
//  `effort=` (solo si no son «por defecto»); en JSON, las claves opcionales `model` y
//  `effort`. Un valor desconocido (de una versión más nueva o de un servidor manipulado) se
//  lee como «por defecto», nunca rompe la lectura.
//

import Foundation

/// Modelo con el que corre el encargo (alias del CLI de Claude Code).
enum ClaudeTaskModel: String, CaseIterable, Sendable {
    case haiku
    case sonnet
    case opus

    /// Nombre comercial: no se traduce.
    var displayName: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }
}

/// Esfuerzo (`--effort` / `/effort` de Claude Code). El CLI recorta el nivel si el modelo
/// no admite tanto.
enum ClaudeTaskEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    var label: String {
        switch self {
        case .low: return String(localized: "Bajo")
        case .medium: return String(localized: "Medio")
        case .high: return String(localized: "Alto")
        case .xhigh: return String(localized: "Muy alto")
        case .max: return String(localized: "Máximo")
        }
    }
}

/// Lo que el despachador apunta (`model_note=`) cuando no pudo hacer su parte en la terminal.
enum ClaudeTaskModelNote: String, Equatable, Sendable {
    /// No se cambió: el valor guardado en los ajustes de Claude Code no se podría volver a poner.
    case unsafe
    /// No se volvió a poner el de antes (la ventana se cerró o no quedó libre en 30 min).
    case kept

    var text: String {
        switch self {
        case .unsafe:
            return String(localized: "No se cambió el modelo: los ajustes de Claude Code tienen un valor que Argos no sabría volver a poner.")
        case .kept:
            return String(localized: "No se pudo volver a poner el modelo de antes en la ventana: compruébalo con /model.")
        }
    }
}

/// Modelo y esfuerzo elegidos (`nil` = el que tenga Claude Code por defecto).
struct ClaudeTaskModelChoice: Equatable, Hashable, Sendable {
    var model: ClaudeTaskModel?
    var effort: ClaudeTaskEffort?

    static let `default` = ClaudeTaskModelChoice()

    init(model: ClaudeTaskModel? = nil, effort: ClaudeTaskEffort? = nil) {
        self.model = model
        self.effort = effort
    }

    /// Desde texto guardado (meta, config, JSON): lo desconocido cuenta como «por defecto».
    init(modelText: String?, effortText: String?) {
        self.model = modelText.flatMap { ClaudeTaskModel(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        self.effort = effortText.flatMap { ClaudeTaskEffort(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }

    var isDefault: Bool { model == nil && effort == nil }

    /// Banderas de `claude` (vacías si todo es «por defecto»). Solo valores de la lista.
    var cliArguments: [String] {
        var arguments: [String] = []
        if let model { arguments += ["--model", model.rawValue] }
        if let effort { arguments += ["--effort", effort.rawValue] }
        return arguments
    }

    /// Líneas `clave=valor` para `meta` y `config` (solo las que no son «por defecto»).
    var keyValueLines: [String] {
        var lines: [String] = []
        if let model { lines.append("model=\(model.rawValue)") }
        if let effort { lines.append("effort=\(effort.rawValue)") }
        return lines
    }

    /// Resumen para la lista («Haiku · esfuerzo bajo»); `nil` si todo es «por defecto».
    var summary: String? {
        let effortText = effort.map { String(localized: "esfuerzo \($0.label.lowercased())") }
        switch (model, effortText) {
        case (nil, nil): return nil
        case (let model?, nil): return model.displayName
        case (nil, let effortText?): return effortText
        case (let model?, let effortText?): return "\(model.displayName) · \(effortText)"
        }
    }
}

extension ClaudeTaskModelChoice: Codable {
    private enum CodingKeys: String, CodingKey {
        case model
        case effort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            modelText: try? container.decodeIfPresent(String.self, forKey: .model),
            effortText: try? container.decodeIfPresent(String.self, forKey: .effort)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model?.rawValue, forKey: .model)
        try container.encodeIfPresent(effort?.rawValue, forKey: .effort)
    }
}

extension ClaudeTaskModelChoice {
    /// Lo que guarda una plantilla de la biblioteca. Un valor que su versión no conoce (se
    /// queda en `extra`) se acepta si está en esta lista (p. ej. `xhigh`).
    init(savedPrompt prompt: SavedPrompt) {
        self.init(
            modelText: prompt.model?.rawValue ?? prompt.extra[SavedPrompt.modelKey]?.stringValue,
            effortText: prompt.effort?.rawValue ?? prompt.extra[SavedPrompt.effortKey]?.stringValue
        )
    }

    /// Elegir una plantilla rellena lo que ella fija y deja lo demás como estaba.
    func applying(_ template: ClaudeTaskModelChoice) -> ClaudeTaskModelChoice {
        ClaudeTaskModelChoice(model: template.model ?? model, effort: template.effort ?? effort)
    }
}
