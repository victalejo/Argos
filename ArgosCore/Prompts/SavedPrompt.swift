//
//  SavedPrompt.swift
//  ArgosCore
//
//  Biblioteca de encargos (lógica pura): prompts guardados en el `projects.json` del
//  servidor, comunes (clave `prompts` del archivo) o de un proyecto (clave `prompts` de
//  cada proyecto). Lo comparten Mac, iPhone/iPad y Android con versiones distintas, así
//  que cada prompt conserva sus claves desconocidas y uno ilegible se guarda tal cual.
//  El servidor no es de fiar: el texto se valida y el título se limpia al mostrarlo.
//

import Foundation

/// Un prompt guardado.
struct SavedPrompt: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var text: String
    /// Modelo con el que conviene ejecutarlo (opcional; p. ej. Haiku para lo mecánico).
    var model: Model?
    /// Esfuerzo de razonamiento (opcional).
    var effort: Effort?
    /// Claves que esta versión no conoce (se conservan al reescribir), incluido un
    /// `model`/`effort` con un valor que no está en las listas.
    var extra: [String: JSONValue] = [:]

    enum Model: String, CaseIterable, Sendable {
        case haiku, sonnet, opus
    }

    enum Effort: String, CaseIterable, Sendable {
        case low, medium, high, max
    }

    static let maxIDLength = 100
    static let maxTitleLength = 200
    /// Como el tope de un encargo de Atajos (`ShortcutTask.maxCharacters`).
    static let maxTextLength = 20_000

    static let knownKeys: Set<String> = ["id", "title", "text"]
    static let modelKey = "model"
    static let effortKey = "effort"

    init(
        id: String = SavedPrompt.makeID(), title: String, text: String,
        model: Model? = nil, effort: Effort? = nil, extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.model = model
        self.effort = effort
        self.extra = extra
    }

    static func makeID() -> String { UUID().uuidString.lowercased() }

    /// `nil` si el objeto no es un prompt válido (se conserva aparte, sin tocarlo).
    init?(json value: JSONValue) {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue, !id.isEmpty, id.count <= Self.maxIDLength,
              let title = object["title"]?.stringValue,
              let text = object["text"]?.stringValue, text.count <= Self.maxTextLength
        else { return nil }
        self.id = id
        // Tal cual: al reescribir el archivo no se cambia el título que puso otro
        // dispositivo. Se limpia al mostrarlo (`displayTitle`).
        self.title = title
        self.text = text
        self.model = object[Self.modelKey]?.stringValue.flatMap(Model.init(rawValue:))
        self.effort = object[Self.effortKey]?.stringValue.flatMap(Effort.init(rawValue:))
        var extra = object.filter { !Self.knownKeys.contains($0.key) }
        // Los reconocidos se escriben desde `model`/`effort`; un valor desconocido se queda.
        if model != nil { extra[Self.modelKey] = nil }
        if effort != nil { extra[Self.effortKey] = nil }
        self.extra = extra
    }

    var json: JSONValue {
        var object = extra
        object["id"] = .string(id)
        object["title"] = .string(title)
        object["text"] = .string(text)
        if let model { object[Self.modelKey] = .string(model.rawValue) }
        if let effort { object[Self.effortKey] = .string(effort.rawValue) }
        return .object(object)
    }

    /// Título visible: una línea, sin caracteres de control y con tope (viene del
    /// servidor); uno vacío muestra el principio del texto.
    var displayTitle: String {
        let trimmed = String(PromptText.singleLine(title).prefix(Self.maxTitleLength))
        if !trimmed.isEmpty { return trimmed }
        return String(PromptText.singleLine(text).prefix(60))
    }
}

/// Lista de prompts tal como está en disco: los válidos en orden y, detrás, los ilegibles.
struct PromptList: Equatable, Sendable {
    var prompts: [SavedPrompt]
    var invalid: [JSONValue]
    /// La clave existe pero no es una lista (otra versión): se lee vacía y no se reescribe.
    var isWritable: Bool

    static let empty = PromptList(prompts: [], invalid: [], isWritable: true)

    static func parse(_ value: JSONValue?) -> PromptList {
        guard let value else { return .empty }
        guard let items = value.arrayValue else { return PromptList(prompts: [], invalid: [], isWritable: false) }
        var prompts: [SavedPrompt] = []
        var invalid: [JSONValue] = []
        var seen: Set<String> = []
        for item in items {
            if let prompt = SavedPrompt(json: item), !seen.contains(prompt.id) {
                seen.insert(prompt.id)
                prompts.append(prompt)
            } else {
                invalid.append(item)
            }
        }
        return PromptList(prompts: prompts, invalid: invalid, isWritable: true)
    }

    var isEmpty: Bool { prompts.isEmpty && invalid.isEmpty }

    /// `nil` = sin nada que guardar (la clave se quita y el archivo queda como antes).
    var json: JSONValue? {
        isEmpty ? nil : .array(prompts.map(\.json) + invalid)
    }

    // MARK: - Cambios (se aplican sobre lo último leído, en cada reintento)

    /// Crea o sustituye (mismo `id`) conservando las claves desconocidas del anterior.
    func upserting(_ prompt: SavedPrompt) -> PromptList {
        var copy = self
        if let index = copy.prompts.firstIndex(where: { $0.id == prompt.id }) {
            var merged = prompt
            merged.extra = copy.prompts[index].extra.merging(prompt.extra) { _, new in new }
            copy.prompts[index] = merged
        } else {
            copy.prompts.append(prompt)
        }
        return copy
    }

    func removing(id: String) -> PromptList {
        var copy = self
        copy.prompts.removeAll { $0.id == id }
        return copy
    }

    /// Ordena según `ids`; los que no aparecen (añadidos en otro dispositivo) van detrás.
    func reordered(_ ids: [String]) -> PromptList {
        var copy = self
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let indexed = prompts.enumerated().map { (offset: $0.offset, prompt: $0.element) }
        copy.prompts = indexed.sorted { lhs, rhs in
            let left = rank[lhs.prompt.id] ?? (ids.count + lhs.offset)
            let right = rank[rhs.prompt.id] ?? (ids.count + rhs.offset)
            return left < right
        }.map(\.prompt)
        return copy
    }
}

/// A quién pertenece un prompt.
enum PromptScope: Hashable, Sendable {
    case common
    case project(UUID)
}

/// La biblioteca de un servidor.
struct PromptLibrary: Equatable, Sendable {
    var common: PromptList
    var byProject: [UUID: PromptList]
    /// Ya se sembraron los ejemplos (no se vuelven a poner aunque se borren).
    var seeded: Bool

    static let empty = PromptLibrary(common: .empty, byProject: [:], seeded: false)

    /// Comunes visibles: antes de sembrar, los ejemplos aparecen ya (mismos `id`).
    var visibleCommon: [SavedPrompt] {
        guard !seeded else { return common.prompts }
        let ids = Set(common.prompts.map(\.id))
        return common.prompts + PromptSeed.examples.filter { !ids.contains($0.id) }
    }

    func projectPrompts(_ id: UUID) -> [SavedPrompt] {
        byProject[id]?.prompts ?? []
    }

    /// Los del proyecto primero y luego los comunes (para los selectores).
    func prompts(forProject id: UUID?) -> [SavedPrompt] {
        let own = id.map(projectPrompts) ?? []
        let ownIDs = Set(own.map(\.id))
        return own + visibleCommon.filter { !ownIDs.contains($0.id) }
    }

    func prompt(id: String, project: UUID?) -> SavedPrompt? {
        prompts(forProject: project).first { $0.id == id }
    }
}

/// Recortes de texto venido del servidor.
enum PromptText {
    /// Una línea: los saltos (también U+2028/U+2029, que no son de control) pasan a
    /// espacio y se quitan los caracteres de control.
    static func singleLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> String in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return " " }
            switch scalar.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator: return " "
            default: break
            }
            return isControl(scalar) ? "" : String(scalar)
        }
        return scalars.joined().trimmingCharacters(in: .whitespaces)
    }

    /// Para pegar en la terminal: sin caracteres de control salvo salto de línea y
    /// tabulador (un ESC podría cerrar el pegado entre corchetes y teclear órdenes).
    static func sanitizedForPaste(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = normalized.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !isControl($0) }
        return String(String.UnicodeScalarView(kept))
    }

    /// Control (Cc) o de formato invisible (Cf: p. ej. U+202E, que invierte el texto).
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }
}
