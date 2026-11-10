//
//  GitWorktreeCommands.swift
//  ArgosCore
//
//  Comandos de worktrees (cadenas puras, testeables) y su parser. Todo bajo `sh`, con
//  rutas y nombres entrecomillados, y git vuelve a validar el nombre de la rama antes de
//  crear nada. Nunca se pisa una carpeta existente.
//

import Foundation

enum GitWorktreeCommands {

    static let marker = "ARGOS_WT:"
    /// Exit code cuando el script se niega (rama no válida, carpeta existente, cambios).
    static let refusedExitCode = 3

    private static func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }

    /// Worktrees (porcelain), cuántos cambios tiene cada uno y las ramas locales, en un
    /// solo round-trip. `GIT_OPTIONAL_LOCKS=0`: un agente puede estar haciendo commits.
    static func list(path: String) -> String {
        ShellQuoting.posixShell("""
        command -v git >/dev/null 2>&1 || { echo \(marker)nogit; exit 0; }
        git -C \(q(path)) rev-parse --git-dir >/dev/null 2>&1 || { echo \(marker)norepo; exit 0; }
        echo \(marker)list
        git -C \(q(path)) worktree list --porcelain
        echo \(marker)end
        git -C \(q(path)) worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r w; do
          n=$(GIT_OPTIONAL_LOCKS=0 git -C "$w" status --porcelain 2>/dev/null | grep -c .)
          printf '%sdirty %s %s\\n' \(marker) "$n" "$w"
        done
        git -C \(q(path)) for-each-ref --format='\(marker)branch %(refname:short)' refs/heads
        """)
    }

    /// Crea el worktree (y la rama, si es nueva) y escribe su ruta real.
    static func add(_ request: GitWorktreeRequest) -> String {
        let git = "git -C \(q(request.repository))"
        let target = request.createsBranch
            ? "-b \(q(request.branch)) \"$d\" \(q(request.base))"
            : "\"$d\" \(q(request.branch))"
        return ShellQuoting.posixShell("""
        \(git) check-ref-format --branch \(q(request.branch)) >/dev/null 2>&1 || { echo \(marker)badbranch; exit \(refusedExitCode); }
        d=\(q(request.path))
        [ -e "$d" ] && { echo \(marker)exists; exit \(refusedExitCode); }
        mkdir -p "$(dirname "$d")" || exit $?
        \(git) worktree add \(target) 2>&1 || exit $?
        cd "$d" && printf '%spath %s\\n' \(marker) "$(pwd -P)"
        """)
    }

    /// Quita el worktree. Sin `force`, git se niega si tiene cambios sin commit o archivos
    /// nuevos (se avisa antes en la UI). La rama NO se borra: sus commits siguen ahí.
    static func remove(repository: String, path: String, force: Bool) -> String {
        ShellQuoting.posixShell(
            "git -C \(q(repository)) worktree remove\(force ? " --force" : "") \(q(path)) 2>&1"
        )
    }
}

enum GitWorktreeParser {

    enum ListResult: Hashable, Sendable {
        case gitMissing
        case notRepository
        case loaded(GitWorktreeListing)
    }

    static func parseList(_ output: String) -> ListResult {
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        if lines.contains(where: { $0.hasSuffix("\(GitWorktreeCommands.marker)nogit") }) { return .gitMissing }
        guard let start = lines.firstIndex(where: { $0.hasSuffix("\(GitWorktreeCommands.marker)list") }) else {
            return .notRepository
        }
        let end = lines[start...].firstIndex(where: { $0.hasSuffix("\(GitWorktreeCommands.marker)end") }) ?? lines.endIndex
        var worktrees = parsePorcelain(Array(lines[(start + 1)..<end]))

        var dirty: [String: Int] = [:]
        var branches: [String] = []
        for line in lines[end...] {
            guard let range = line.range(of: GitWorktreeCommands.marker) else { continue }
            let rest = line[range.upperBound...]
            if rest.hasPrefix("dirty ") {
                let fields = rest.dropFirst(6).split(separator: " ", maxSplits: 1)
                if fields.count == 2, let count = Int(fields[0]) { dirty[String(fields[1])] = count }
            } else if rest.hasPrefix("branch ") {
                branches.append(String(rest.dropFirst(7)))
            }
        }
        for index in worktrees.indices { worktrees[index].changedCount = dirty[worktrees[index].path] }
        return .loaded(GitWorktreeListing(worktrees: worktrees, branches: branches))
    }

    /// Bloques `worktree <ruta>` / `HEAD <sha>` / `branch refs/heads/x` | `detached` /
    /// `bare` / `locked [motivo]` / `prunable [motivo]`, separados por una línea vacía.
    /// El primero es el principal.
    static func parsePorcelain(_ lines: [String]) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var path: String?
        var head = ""
        var branch: String?
        var bare = false
        var locked = false
        var prunable = false

        /// Con un repo «bare» el primer bloque no tiene carpeta: ningún worktree es el principal.
        var bareFirst = false
        var blocks = 0

        func flush() {
            defer { path = nil; head = ""; branch = nil; bare = false; locked = false; prunable = false }
            guard let path else { return }
            blocks += 1
            if bare {
                if blocks == 1 { bareFirst = true }
                return
            }
            result.append(GitWorktree(path: path, head: head, branch: branch, isMain: blocks == 1 && !bareFirst,
                                      isLocked: locked, isPrunable: prunable, changedCount: nil))
        }

        for line in lines {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                if path != nil { flush() }
                path = String(line.dropFirst(9))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst(7))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
            } else if line == "bare" {
                bare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            }
        }
        flush()
        return result
    }

    /// Ruta real del worktree creado (`nil` si la salida no la trae).
    static func addedPath(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            if let range = line.range(of: "\(GitWorktreeCommands.marker)path ") {
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { return path }
            }
        }
        return nil
    }

    /// Por qué se negó el script de `add`.
    static func addRefusal(_ output: String) -> String? {
        if output.contains("\(GitWorktreeCommands.marker)badbranch") {
            return GitWorktreeRequest.ValidationError.invalidBranch.errorDescription
        }
        if output.contains("\(GitWorktreeCommands.marker)exists") {
            return "Ya existe una carpeta en esa ruta. Elige otra."
        }
        return nil
    }
}
