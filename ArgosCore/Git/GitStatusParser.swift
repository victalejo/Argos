//
//  GitStatusParser.swift
//  ArgosCore
//
//  Parser puro de la salida de `GitCommands.status`: primera línea = marcador o raíz
//  del repo; después, `git status --porcelain=v1 -z -b` (entradas separadas por NUL).
//

import Foundation

enum GitStatusParser {

    /// Máximo de archivos que se muestran (el resto se marca como recortado).
    static let maxChanges = 2000

    static func parse(_ output: String) -> GitStatusResult {
        // El perfil del shell puede ensuciar el principio: se busca la línea marcadora.
        guard let markerRange = output.range(of: GitCommands.rootMarker) else {
            if output.contains(GitCommands.noGitMarker) { return .gitMissing }
            return .notRepository
        }
        let afterMarker = output[markerRange.upperBound...]
        guard let newline = afterMarker.firstIndex(of: "\n") else { return .notRepository }
        let root = String(afterMarker[..<newline]).trimmingCharacters(in: .whitespaces)
        guard root.hasPrefix("/") else { return .notRepository }

        let body = afterMarker[afterMarker.index(after: newline)...]
        return .repository(parsePorcelain(String(body), root: root))
    }

    /// Parsea la parte porcelain (`-z -b`).
    static func parsePorcelain(_ body: String, root: String) -> GitRepositoryStatus {
        var fields = body.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // Un `-z` termina en NUL: el último campo vacío (o cortado por `head -c`) sobra.
        if let last = fields.last, last.isEmpty || !body.hasSuffix("\0") { fields.removeLast() }

        var branch = GitBranchInfo.unknown
        var changes: [GitFileChange] = []
        var truncated = !body.hasSuffix("\0") && !body.isEmpty
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            if field.hasPrefix("## ") {
                branch = parseBranch(String(field.dropFirst(3)))
                continue
            }
            guard let change = parseEntry(field) else { continue }
            var original: String?
            if change.needsOriginal {
                guard index < fields.count else { break }
                original = fields[index]
                index += 1
            }
            if changes.count >= maxChanges {
                truncated = true
                continue
            }
            changes.append(GitFileChange(
                path: change.path, originalPath: original,
                indexCode: change.x, worktreeCode: change.y
            ))
        }
        return GitRepositoryStatus(root: root, branch: branch, changes: changes, truncated: truncated)
    }

    private struct Entry {
        let x: Character
        let y: Character
        let path: String
        var needsOriginal: Bool { x == "R" || x == "C" || y == "R" || y == "C" }
    }

    /// `XY ruta` (dos letras de estado, un espacio y la ruta).
    private static func parseEntry(_ field: String) -> Entry? {
        let chars = Array(field)
        guard chars.count >= 4, chars[2] == " " else { return nil }
        return Entry(x: chars[0], y: chars[1], path: String(chars[3...]))
    }

    /// Cabecera `-b`. Formas:
    ///  - `main`
    ///  - `main...origin/main [ahead 1, behind 2]`
    ///  - `main...origin/main [gone]`
    ///  - `No commits yet on main` / `Initial commit on main` (git antiguo)
    ///  - `HEAD (no branch)`
    static func parseBranch(_ header: String) -> GitBranchInfo {
        for prefix in ["No commits yet on ", "Initial commit on "] where header.hasPrefix(prefix) {
            return GitBranchInfo(
                name: String(header.dropFirst(prefix.count)), upstream: nil,
                ahead: 0, behind: 0, hasCommits: false, upstreamGone: false
            )
        }
        if header.hasPrefix("HEAD (no branch)") {
            return GitBranchInfo(name: nil, upstream: nil, ahead: 0, behind: 0,
                                 hasCommits: true, upstreamGone: false)
        }

        var refs = header
        var tracking = ""
        if let bracket = header.range(of: " [", options: .backwards), header.hasSuffix("]") {
            refs = String(header[..<bracket.lowerBound])
            tracking = String(header[bracket.upperBound..<header.index(before: header.endIndex)])
        }
        let parts = refs.components(separatedBy: "...")
        let name = parts[0]
        let upstream = parts.count > 1 ? parts[1] : nil
        return GitBranchInfo(
            name: name.isEmpty ? nil : name,
            upstream: upstream,
            ahead: count(of: "ahead", in: tracking),
            behind: count(of: "behind", in: tracking),
            hasCommits: true,
            upstreamGone: tracking == "gone"
        )
    }

    private static func count(of word: String, in tracking: String) -> Int {
        for item in tracking.components(separatedBy: ", ") {
            let pieces = item.split(separator: " ")
            if pieces.count == 2, pieces[0] == word, let value = Int(pieces[1]) { return value }
        }
        return 0
    }
}
