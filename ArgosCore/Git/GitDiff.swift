//
//  GitDiff.swift
//  ArgosCore
//
//  Diff unificado de un archivo, ya parseado en líneas con su tipo y sus números de
//  línea (lógica pura). Lo produce `GitDiffParser` a partir de `git diff`.
//

import Foundation

/// Tipo de una línea del diff.
enum GitDiffLineKind: Sendable, Hashable {
    /// Cabeceras previas al primer hunk (`diff --git`, `index`, `---`, `+++`, modos…).
    case meta
    /// `@@ -a,b +c,d @@ contexto`.
    case hunk
    case context
    case added
    case removed
    /// `\ No newline at end of file`.
    case noNewline
}

struct GitDiffLine: Identifiable, Hashable, Sendable {
    let id: Int
    let kind: GitDiffLineKind
    /// Texto sin el prefijo `+`/`-`/` ` (las cabeceras y hunks van completos).
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

struct GitFileDiff: Hashable, Sendable {
    let lines: [GitDiffLine]
    let isBinary: Bool
    /// La salida superó el límite y se recortó.
    let truncated: Bool

    var additions: Int { lines.filter { $0.kind == .added }.count }
    var deletions: Int { lines.filter { $0.kind == .removed }.count }
    /// Sin hunks: p. ej. solo cambió el modo del archivo.
    var hasContent: Bool { lines.contains { $0.kind == .hunk } }

    static let empty = GitFileDiff(lines: [], isBinary: false, truncated: false)
}

enum GitDiffParser {

    static func parse(_ output: String, truncated: Bool = false) -> GitFileDiff {
        var lines: [GitDiffLine] = []
        var isBinary = false
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        var rawLines = output.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        // Si se recortó, la última línea puede estar a medias: se descarta.
        if truncated, !rawLines.isEmpty { rawLines.removeLast() }

        for raw in rawLines {
            let id = lines.count
            if raw.hasPrefix("diff --git ") || raw.hasPrefix("diff --cc ") {
                inHunk = false
                lines.append(GitDiffLine(id: id, kind: .meta, text: raw, oldNumber: nil, newNumber: nil))
                continue
            }
            if raw.hasPrefix("@@") {
                if let (old, new) = hunkStarts(raw) {
                    oldLine = old
                    newLine = new
                    inHunk = true
                }
                lines.append(GitDiffLine(id: id, kind: .hunk, text: raw, oldNumber: nil, newNumber: nil))
                continue
            }
            guard inHunk else {
                if raw.hasPrefix("Binary files ") || raw.hasPrefix("GIT binary patch") { isBinary = true }
                lines.append(GitDiffLine(id: id, kind: .meta, text: raw, oldNumber: nil, newNumber: nil))
                continue
            }
            switch raw.first {
            case "+":
                lines.append(GitDiffLine(id: id, kind: .added, text: String(raw.dropFirst()),
                                         oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "-":
                lines.append(GitDiffLine(id: id, kind: .removed, text: String(raw.dropFirst()),
                                         oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case "\\":
                lines.append(GitDiffLine(id: id, kind: .noNewline, text: raw, oldNumber: nil, newNumber: nil))
            default:
                // Contexto (` texto`) o línea vacía de contexto que algún git deja sin espacio.
                lines.append(GitDiffLine(id: id, kind: .context, text: String(raw.dropFirst()),
                                         oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return GitFileDiff(lines: lines, isBinary: isBinary, truncated: truncated)
    }

    /// Números iniciales de `@@ -a[,b] +c[,d] @@`.
    static func hunkStarts(_ header: String) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3,
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0])
        else { return nil }
        return (old, new)
    }
}
