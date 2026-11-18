//
//  CheckpointCommands.swift
//  ArgosCore
//
//  Comandos remotos de los puntos de restauración (cadenas puras). Todos ejecutan el
//  script completo (`CheckpointScript.source`) con `sh -c` y le pasan cada argumento
//  entre comillas simples (`ShellQuoting`): rutas y referencias nunca se interpolan en
//  el script, y las rutas que git usa van con `--literal-pathspecs`.
//

import Foundation

enum CheckpointCommands {

    /// Referencia que el script entiende como «el árbol de trabajo actual».
    static let worktree = "-"

    static func invocation(_ arguments: [String]) -> String {
        ([ShellQuoting.posixShell(CheckpointScript.source), CheckpointScript.processName]
            + arguments.map(ShellQuoting.singleQuoted))
            .joined(separator: " ")
    }

    static func list(path: String) -> String { invocation(["list", path]) }

    /// Archivos que difieren de `from` a `to` (commits, o `worktree`).
    static func files(root: String, from: String, to: String) -> String {
        invocation(["files", root, from, to])
    }

    /// Diff de un archivo de `from` a `to`, recortado a `GitCommands.diffByteLimit` + 1.
    static func diff(root: String, from: String, to: String, path: String) -> String {
        invocation(["diff", root, from, to, path, String(GitCommands.diffByteLimit + 1)])
    }

    /// `force`: hacer la copia del estado actual aunque sea costosa (tras avisar).
    static func preview(root: String, commit: String, force: Bool) -> String {
        invocation(["preview", root, commit, force ? "full" : "guard"])
    }

    /// Restaura el punto entero (`path == nil`) o un archivo. `expectedTree`: el árbol que
    /// vio la vista previa (si el actual difiere, no toca nada); `nil` para no comprobar.
    static func restore(root: String, commit: String, expectedTree: String?, path: String?) -> String {
        var arguments = ["restore", root, commit, expectedTree ?? worktree]
        if let path { arguments.append(path) }
        return invocation(arguments)
    }

    static func snapshot(root: String, label: String) -> String {
        invocation(["snapshot", root, label])
    }

    /// Activa la captura en el repositorio (`git config argos.checkpoints true`).
    static func enable(root: String) -> String { invocation(["enable", root]) }

    /// La desactiva y borra todos sus puntos e índices privados.
    static func disable(root: String) -> String { invocation(["disable", root]) }

    /// Borra todos los puntos del repositorio (sigue activado).
    static func purge(root: String) -> String { invocation(["purge", root]) }

    /// Guardar (o no) un extracto de cada mensaje en el punto.
    static func storePrompts(root: String, _ enabled: Bool) -> String {
        invocation(["prompts", root, enabled ? "true" : "false"])
    }

    /// Borra el script instalado (al quitar el hook del servidor).
    static func removeScript() -> String { invocation(["remove-script"]) }
}

enum CheckpointParser {

    private static let recordSeparator: Character = "\u{1e}"
    private static let fieldSeparator: Character = "\u{1f}"

    // MARK: - Lista

    static func parseList(_ output: String) throws -> CheckpointListResult {
        let lines = output.components(separatedBy: "\n")
        if lines.contains("ARGOS_CP_NOGIT") { return .gitMissing }
        if lines.contains("ARGOS_CP_NOREPO") { return .notRepository }
        guard let start = lines.firstIndex(of: "ARGOS_CP_LIST 2"),
              let metaIndex = lines[start...].firstIndex(of: "ARGOS_CP_META")
        else { throw CheckpointError.unexpectedOutput("") }

        var enabled = false, prompts = false
        var root = ""
        var head: String?
        var skips: [CheckpointSkip] = []
        var currentSkip: String?
        var counts: [String: Int] = [:]
        for line in lines[start..<metaIndex] {
            if let value = line.value(after: "ARGOS_CP_STATE ") {
                enabled = value == "on"
            } else if let value = line.value(after: "ARGOS_CP_PROMPTS ") {
                prompts = value == "on"
            } else if let value = line.value(after: "ARGOS_CP_ROOT ") {
                root = value
            } else if let value = line.value(after: "ARGOS_CP_HEAD ") {
                head = value == "-" ? nil : value
            } else if let value = line.value(after: "ARGOS_CP_SKIPLOG ") {
                if let skip = parseSkip(value) { skips.append(skip) }
            } else if let value = line.value(after: "ARGOS_CP_CURRENT_SKIPPED ") {
                currentSkip = value
            } else if let value = line.value(after: "ARGOS_CP_COUNT ") {
                let parts = value.split(separator: " ")
                if parts.count == 2, let count = Int(parts[1]) { counts[String(parts[0])] = count }
            }
        }
        let meta = lines[(metaIndex + 1)...].joined(separator: "\n")
        let checkpoints = parseRecords(meta, counts: counts)
        return .listing(CheckpointListing(
            root: root, isEnabled: enabled, storesPrompts: prompts, headCommit: head,
            checkpoints: checkpoints, skips: skips, currentSkipReason: currentSkip
        ))
    }

    private static func parseSkip(_ value: String) -> CheckpointSkip? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let epoch = TimeInterval(parts[0]) else { return nil }
        return CheckpointSkip(date: Date(timeIntervalSince1970: epoch), reason: String(parts[1]))
    }

    static func parseRecords(_ text: String, counts: [String: Int]) -> [Checkpoint] {
        text.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count >= 5, fields[0].hasPrefix(CheckpointScript.refPrefix),
                  let epoch = TimeInterval(fields[3])
            else { return nil }
            let commit = String(fields[1])
            let parent = fields[2].split(separator: " ").first.map(String.init)
            let message = parseMessage(String(fields[4]))
            return Checkpoint(
                ref: String(fields[0]), commit: commit, parent: parent,
                date: Date(timeIntervalSince1970: epoch), kind: message.kind,
                sessionID: message.session, label: message.subject, changedFiles: counts[commit]
            )
        }
    }

    /// Asunto (el extracto) y metadatos `Argos-Kind` / `Argos-Session` del mensaje.
    static func parseMessage(_ message: String) -> (subject: String, kind: CheckpointKind, session: String?) {
        let lines = message.components(separatedBy: "\n")
        let subject = cleanLabel(lines.first ?? "")
        var kind = CheckpointKind.unknown
        var session: String?
        for line in lines.dropFirst() {
            if let value = line.value(after: "Argos-Kind: ") { kind = CheckpointKind(rawValue: value) ?? .unknown }
            if let value = line.value(after: "Argos-Session: "), value != "-", !value.isEmpty { session = value }
        }
        return (subject, kind, session)
    }

    /// El script recorta por bytes: un carácter multibyte cortado llega como U+FFFD.
    static func cleanLabel(_ label: String) -> String {
        var result = label.trimmingCharacters(in: .whitespaces)
        let cut = result.hasSuffix("...")
        if cut { result.removeLast(3) }
        while result.hasSuffix("\u{FFFD}") { result.removeLast() }
        return cut ? result + "…" : result
    }

    // MARK: - Archivos, vista previa y restauración

    /// `git diff-tree -z --name-status` tras el marcador `ARGOS_CP_FILES`.
    /// Árboles comparados (`ARGOS_CP_TREES de a`): el segundo es el actual si se pidió `-`.
    static func parseTrees(_ output: String) -> (from: String, to: String)? {
        for line in output.components(separatedBy: "\n") {
            guard let value = line.value(after: "ARGOS_CP_TREES ") else { continue }
            let parts = value.split(separator: " ")
            if parts.count == 2 { return (String(parts[0]), String(parts[1])) }
        }
        return nil
    }

    static func parseFiles(_ output: String) throws -> [CheckpointFileChange] {
        try throwIfFailed(output)
        guard let range = output.range(of: "ARGOS_CP_FILES\n") else {
            throw CheckpointError.unexpectedOutput("")
        }
        return parseNameStatus(String(output[range.upperBound...]))
    }

    static func parseNameStatus(_ text: String) -> [CheckpointFileChange] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var changes: [CheckpointFileChange] = []
        var index = 0
        while index + 1 < fields.count {
            let status = fields[index], path = fields[index + 1]
            index += 2
            guard !path.isEmpty, let kind = kind(status) else { continue }
            changes.append(CheckpointFileChange(path: path, kind: kind))
        }
        return changes
    }

    private static func kind(_ status: String) -> CheckpointFileChange.Kind? {
        switch status.first {
        case "A": return .added
        case "D": return .deleted
        case "M": return .modified
        case "T": return .typeChanged
        default: return nil
        }
    }

    /// Vista previa: los cambios van del árbol ACTUAL al del punto.
    static func parsePreview(_ output: String, checkpoint: Checkpoint) throws -> CheckpointPreviewResult {
        try throwIfFailed(output, allowHeavy: true)
        let lines = output.components(separatedBy: "\n")
        if let reason = lines.lazy.compactMap({ $0.value(after: "ARGOS_CP_HEAVY ") }).first {
            return .heavy(reason)
        }
        guard let tree = lines.lazy.compactMap({ $0.value(after: "ARGOS_CP_CURRENT ") }).first else {
            throw CheckpointError.unexpectedOutput("")
        }
        let moved = lines.lazy.compactMap { $0.value(after: "ARGOS_CP_HEADMOVED ") }.first.flatMap(Int.init) ?? 0
        let changes = try parseFiles(output)
        return .ready(CheckpointRestorePreview(
            checkpoint: checkpoint, currentTree: tree,
            toModify: changes.filter { $0.kind == .modified || $0.kind == .typeChanged }.map(\.path),
            toDelete: changes.filter { $0.kind == .deleted }.map(\.path),
            toRecreate: changes.filter { $0.kind == .added }.map(\.path),
            commitsSince: moved,
            issues: parseIssues(output, after: "ARGOS_CP_CHECK\n")
        ))
    }

    /// Registros `tipo\0ruta\0` tras `marker`, hasta el registro `END`.
    static func parseIssues(_ output: String, after marker: String) -> [CheckpointIssue] {
        guard let range = output.range(of: marker) else { return [] }
        let tokens = output[range.upperBound...].split(separator: "\0", omittingEmptySubsequences: false)
        var issues: [CheckpointIssue] = []
        var index = 0
        while index + 1 < tokens.count, tokens[index] != "END" {
            if let kind = CheckpointIssue.Kind(rawValue: String(tokens[index])) {
                issues.append(CheckpointIssue(kind: kind, path: String(tokens[index + 1])))
            }
            index += 2
        }
        return issues
    }

    static func parseRestore(_ output: String) throws -> CheckpointRestoreOutcome {
        try throwIfFailed(output)
        let lines = output.components(separatedBy: "\n")
        let backup = lines.lazy.compactMap { line -> String? in
            guard let value = line.value(after: "ARGOS_CP_NEW ") ?? line.value(after: "ARGOS_CP_SAME ") else { return nil }
            return value.split(separator: " ").first.map(String.init)
        }.first
        if lines.contains("ARGOS_CP_CHANGED") { return .changed }
        if lines.contains("ARGOS_CP_CONFLICT") {
            return .conflict(parseIssues(output, after: "ARGOS_CP_CONFLICT\n"))
        }
        if let reason = lines.lazy.compactMap({ $0.value(after: "ARGOS_CP_NOOP ") }).first {
            return .nothing(noopText(reason))
        }
        if lines.contains("ARGOS_CP_PARTIAL") { return .partial(backup: backup) }
        if lines.contains("ARGOS_CP_DONE") { return .done(backup: backup) }
        throw CheckpointError.unexpectedOutput("")
    }

    static func noopText(_ reason: String) -> String {
        if let kind = CheckpointIssue.Kind(rawValue: reason) {
            return "No se tocó: \(CheckpointIssue(kind: kind, path: "").explanation)."
        }
        switch reason {
        case "invalid": return "No se tocó: la ruta no es válida dentro del repositorio."
        case "absent": return "No había nada que restaurar: el archivo no existe ni existía en ese punto."
        default: return "No se tocó nada (\(reason))."
        }
    }

    /// Ref del punto creado a mano (`nil` si el árbol era idéntico al último).
    static func parseSnapshot(_ output: String) throws -> String? {
        try throwIfFailed(output)
        let lines = output.components(separatedBy: "\n")
        if let value = lines.lazy.compactMap({ $0.value(after: "ARGOS_CP_NEW ") }).first {
            return value.split(separator: " ").first.map(String.init)
        }
        if lines.contains(where: { $0.hasPrefix("ARGOS_CP_SAME ") }) { return nil }
        if let reason = lines.lazy.compactMap({ $0.value(after: "ARGOS_CP_SKIP ") }).first {
            throw CheckpointError.failed(reason)
        }
        throw CheckpointError.unexpectedOutput("")
    }

    /// Marcadores de error comunes a todos los modos.
    static func throwIfFailed(_ output: String, allowHeavy: Bool = false) throws {
        for line in output.components(separatedBy: "\n") {
            if let operation = line.value(after: "ARGOS_CP_BUSY ") { throw CheckpointError.busy(operation) }
            if let reason = line.value(after: "ARGOS_CP_HEAVY "), !allowHeavy { throw CheckpointError.heavy(reason) }
            if line == "ARGOS_CP_BADREF" { throw CheckpointError.badReference }
            if let detail = line.value(after: "ARGOS_CP_FAILED ") { throw CheckpointError.failed(detail) }
            if line == "ARGOS_CP_NOREPO" {
                throw CheckpointError.unexpectedOutput("La carpeta ya no es un repositorio git.")
            }
            if line == "ARGOS_CP_NOGIT" {
                throw CheckpointError.unexpectedOutput("git no está instalado en el servidor.")
            }
        }
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
