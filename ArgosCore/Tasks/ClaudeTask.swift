//
//  ClaudeTask.swift
//  ArgosCore
//
//  Encargos de la cola de un proyecto (lógica pura): lo que la app sube al encolar y lo
//  que lee del servidor (ver `ClaudeTaskScript` y `docs/encargos.md`). El servidor no es de
//  fiar: estados y motivos desconocidos se toleran y los textos llegan recortados.
//

import Foundation

enum ClaudeTaskState: String, Equatable, Sendable {
    case pending
    case running
    case done
    case failed
    case paused
    case cancelled

    var label: String {
        switch self {
        case .pending: return String(localized: "En cola")
        case .running: return String(localized: "En curso")
        case .done: return String(localized: "Hecho")
        case .failed: return String(localized: "Falló")
        case .paused: return String(localized: "En pausa")
        case .cancelled: return String(localized: "Cancelado")
        }
    }

    /// Aún puede ejecutarse (cuenta para la insignia «N en cola»).
    var isOpen: Bool { self == .pending || self == .running || self == .paused }
}

/// Por qué un encargo espera, se pausó o falló (lo escribe el despachador).
enum ClaudeTaskReason: String, Equatable, Sendable {
    case busy
    case noPane = "no-pane"
    case noClaude = "no-claude"
    case limit
    case memory
    case api
    case tmux
    case commit
    case push
    case agent
    case timeout
    case check
    /// El revisor automático está mirando los cambios antes del push.
    case reviewing
    /// El revisor bloqueó el push (informe en `review.json`).
    case review
    /// El revisor no fue concluyente (plazo, JSON roto…): también bloquea.
    case reviewInconclusive = "review-inconclusive"
    /// Lo bloqueado se encargó a Claude para que lo arregle (otro encargo).
    case reviewFixing = "review-fixing"
    /// «Subir igualmente»: el push está en marcha.
    case pushing

    var text: String {
        switch self {
        case .busy: return String(localized: "Espera a que Claude termine lo que está haciendo.")
        case .noPane: return String(localized: "La ventana del proyecto ya no existe: abre el proyecto o elige otra ventana.")
        case .noClaude: return String(localized: "Claude no está abierto en esa ventana: arráncalo y el encargo empezará solo.")
        case .limit: return String(localized: "Pausado por el límite de uso de Claude: sigue solo cuando se reinicie la ventana.")
        case .memory: return String(localized: "Espera: el servidor va justo de memoria.")
        case .api: return String(localized: "Claude se detuvo por un error de la API. Reinténtalo cuando quieras.")
        case .tmux: return String(localized: "No se pudo escribir en la ventana de tmux.")
        case .commit: return String(localized: "Terminó, pero no se pudo hacer el commit.")
        case .push: return String(localized: "Terminó y se hizo el commit, pero no se pudo subir (push).")
        case .agent: return String(localized: "No se pudo arrancar el agente del encargo (¿existe ya la rama o la carpeta?).")
        case .timeout: return String(localized: "Se detuvo por pasar de su tiempo máximo.")
        case .check: return String(localized: "Terminó, pero la comprobación no pasó: no se subió a main (la rama queda con el commit).")
        case .reviewing: return String(localized: "El revisor automático está mirando los cambios antes de subirlos.")
        case .review: return String(localized: "El revisor automático bloqueó el push: el commit queda en su rama.")
        case .reviewInconclusive: return String(localized: "La revisión automática no fue concluyente: no se subió (el commit queda en su rama).")
        case .reviewFixing: return String(localized: "El revisor lo bloqueó y se pidió a Claude que lo arregle en otro encargo.")
        case .pushing: return String(localized: "Subiendo (push) sin la aprobación del revisor…")
        }
    }
}

/// Un encargo tal como lo lista el servidor.
struct ClaudeTask: Identifiable, Equatable, Sendable {
    /// Clave del proyecto (`ClaudeUsageProjects.key(forPath:)`).
    let projectKey: String
    /// Carpeta del encargo: `<seq>-<id>`.
    let folder: String
    let state: ClaudeTaskState?
    let reason: ClaudeTaskReason?
    let started: Date?
    let finished: Date?
    let title: String
    let promptPreview: String
    let cleanContext: Bool
    let commit: Bool
    let window: Int?
    /// Corre en un agente persistente en su propia rama (no en la terminal).
    let isAgent: Bool
    /// Rama del worktree del encargo (solo en agente).
    let branch: String?
    /// Lo que hace falta para «Pedir a Claude que lo arregle» (del `meta`).
    var push = false
    var directory: String?
    var session: String?
    var checkCommand: String?
    var maxMinutes: Int?
    /// Informe del revisor (solo si bloqueó o no fue concluyente).
    var review: ClaudeTaskReview?
    /// Veredicto de una revisión que no bloqueó (p. ej. `approve`).
    var reviewedVerdict: String?

    /// El revisor lo dejó en pausa: «Subir igualmente» o «Pedir a Claude que lo arregle».
    var isBlockedByReview: Bool {
        state == .paused && (reason == .review || reason == .reviewInconclusive)
    }

    var id: String { "\(projectKey)/\(folder)" }
    var sequence: Int { Int(folder.prefix { $0.isNumber }) ?? 0 }

    /// Salida de `ClaudeTaskScript.listCommand`.
    static func parse(listOutput output: String) -> [ClaudeTask] {
        var tasks: [ClaudeTask] = []
        var current: Builder?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@task ") {
                if let built = current?.build() { tasks.append(built) }
                current = Builder(path: String(line.dropFirst(7)))
            } else {
                current?.absorb(line)
            }
        }
        if let built = current?.build() { tasks.append(built) }
        return tasks.sorted { ($0.projectKey, $0.sequence) < ($1.projectKey, $1.sequence) }
    }

    private struct Builder {
        let path: String
        var fields: [String: String] = [:]
        var meta: [String: String] = [:]

        init(path: String) { self.path = path }

        mutating func absorb(_ line: String) {
            guard let space = line.firstIndex(of: " ") else { return }
            let key = String(line[..<space])
            let value = String(line[line.index(after: space)...])
            if key == "meta" {
                guard let equals = value.firstIndex(of: "=") else { return }
                let metaKey = String(value[..<equals])
                if meta[metaKey] == nil { meta[metaKey] = String(value[value.index(after: equals)...]) }
            } else {
                fields[key] = value
            }
        }

        func build() -> ClaudeTask? {
            let parts = path.split(separator: "/")
            guard parts.count == 2, Self.isSafe(parts[0]), Self.isSafe(parts[1]) else { return nil }
            func date(_ key: String) -> Date? { fields[key].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
            let preview = String((fields["prompt"] ?? "").trimmingCharacters(in: .whitespaces).prefix(400))
            let title = String((meta["title"] ?? "").prefix(200))
            var task = ClaudeTask(
                projectKey: String(parts[0]), folder: String(parts[1]),
                state: fields["state"].flatMap { ClaudeTaskState(rawValue: $0.trimmingCharacters(in: .whitespaces)) },
                reason: fields["reason"].flatMap { ClaudeTaskReason(rawValue: $0.trimmingCharacters(in: .whitespaces)) },
                started: date("started"), finished: date("finished"),
                title: title.isEmpty ? String(preview.prefix(80)) : title,
                promptPreview: preview,
                cleanContext: meta["context"] == "clear",
                commit: meta["commit"] == "1",
                window: meta["window"].flatMap(Int.init),
                isAgent: meta["target"] == "agent",
                branch: meta["branch"].map { String($0.prefix(200)) }
            )
            task.push = meta["push"] == "1"
            task.directory = meta["dir"].map { String($0.prefix(1024)) }
            task.session = meta["session"].map { String($0.prefix(200)) }
            task.checkCommand = meta["check"].map { String($0.prefix(1024)) }.flatMap { $0.isEmpty ? nil : $0 }
            task.maxMinutes = meta["max_minutes"].flatMap(Int.init)
            task.review = fields["review"].flatMap(ClaudeTaskReview.parse)
            task.reviewedVerdict = fields["reviewed"].map { String($0.trimmingCharacters(in: .whitespaces).prefix(16)) }
            return task
        }

        private static func isSafe(_ text: Substring) -> Bool {
            !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }
}

/// Lo que la app pide al encolar.
struct ClaudeTaskRequest: Equatable, Sendable {

    /// Dónde corre: el Claude de la terminal del proyecto o un agente persistente aparte,
    /// en su propio worktree y rama.
    enum Target: Equatable, Sendable {
        case terminal
        case agent(id: String, worktree: String, branch: String)
    }

    var prompt: String
    var session: String
    var window: Int
    var target: Target = .terminal
    /// Modo de permisos del agente (solo en agente): el de Ajustes para ese proyecto.
    var permissionMode: ClaudeAgentCommand.PermissionMode = AgentPermissionPreferences.fallback
    /// Título fijo (tareas programadas); si no, la primera línea del encargo.
    var customTitle: String?
    /// Identificador del encargo (también nombra su worktree y su rama).
    var taskID = ClaudeTaskRequest.makeID()
    var cleanContext = false
    var commit = false
    var push = false
    var source = "manual"
    var reference: String?
    /// En agente: el worktree ya existe (arreglo de un encargo en su misma rama).
    var reuseWorktree = false
    /// Claves extra del `meta` (p. ej. `fixes`, `check`, `claude`), en orden alfabético.
    var extraMeta: [String: String] = [:]

    /// Título: primera línea con texto, recortada.
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        let first = prompt.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let line = first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return line.count > 72 ? String(line.prefix(71)) + "…" : line
    }

    /// Contenido de `meta` (una clave por línea; sin saltos de línea en los valores).
    func metaText(directory: String) -> String {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        var lines = ["v=1", "title=\(clean(title))", "source=\(clean(source))"]
        switch target {
        case .terminal:
            lines += [
                "target=terminal", "session=\(clean(session))", "window=\(window)",
                "context=\(cleanContext ? "clear" : "same")", "dir=\(clean(directory))",
            ]
        case .agent(let id, let worktree, let branch):
            lines += ["target=agent", "agent=\(clean(id))", "branch=\(clean(branch))", "dir=\(clean(worktree))"]
        }
        lines += ["commit=\(commit ? 1 : 0)", "push=\(push ? 1 : 0)"]
        if let reference { lines.append("ref=\(clean(reference))") }
        for key in extraMeta.keys.sorted() where !key.isEmpty && key.allSatisfy({ $0.isLetter || $0 == "_" }) {
            lines.append("\(key)=\(clean(extraMeta[key] ?? ""))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Worktree y rama de un encargo en agente: junto al proyecto, con el id del encargo.
    static func agentTarget(projectPath: String, taskID: String) -> Target {
        let folder = (projectPath as NSString).lastPathComponent
        let parent = (projectPath as NSString).deletingLastPathComponent
        return .agent(
            id: UUID().uuidString.lowercased(),
            worktree: "\(parent)/\(folder)-encargo-\(taskID)",
            branch: "argos/encargo-\(taskID)"
        )
    }

    /// Identificador del encargo: aleatorio y seguro para rutas.
    static func makeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }
}
