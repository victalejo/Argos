//
//  GitCommands.swift
//  ArgosCore
//
//  Comandos git remotos (cadenas puras, testeables). Todas las rutas van entrecomilladas
//  con `ShellQuoting` y se ejecutan bajo `sh` (`ShellQuoting.posixShell`) con
//  `git -C <raíz>`: nunca se interpola texto del usuario sin comillas.
//

import Foundation

enum GitCommands {

    /// Marcadores de la salida de `status` (el perfil del shell puede ensuciar el inicio).
    static let rootMarker = "ARGOS_GIT_ROOT:"
    static let noGitMarker = "ARGOS_NO_GIT"

    /// Límite de bytes de la salida de `status` y de un diff (evita traer megas por SSH).
    static let statusByteLimit = 2_000_000
    static let diffByteLimit = 512_000

    /// Entorno para operaciones de red: git nunca se queda esperando una contraseña en
    /// un canal sin TTY (fallaría en vez de colgarse). Respeta un `GIT_SSH_COMMAND` propio.
    static let nonInteractiveEnv =
        "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=\"${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}\""

    private static func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }

    /// `git` sobre `root` con rutas LITERALES: los nombres de archivo vienen del servidor
    /// (o de un agente) y git interpretaría `*`, `?`, `[…]` o `:(glob)` como patrones,
    /// así que descartar el archivo `*` haría `clean -f` de TODOS los no seguidos. El
    /// entrecomillado del shell no lo evita: quien expande es git.
    static func git(_ root: String) -> String {
        "git --literal-pathspecs -C \(q(root))"
    }

    private static func pathspec(_ paths: [String]) -> String {
        paths.map(q).joined(separator: " ")
    }

    /// Raíz del repo + estado porcelain en un solo round-trip. `GIT_OPTIONAL_LOCKS=0`:
    /// no toma el lock del índice, así no choca con un agente que esté haciendo commits.
    static func status(path: String) -> String {
        ShellQuoting.posixShell("""
        command -v git >/dev/null 2>&1 || { echo \(noGitMarker); exit 0; }
        top=$(git -C \(q(path)) rev-parse --show-toplevel 2>/dev/null) || exit 0
        printf '%s%s\\n' '\(rootMarker)' "$top"
        GIT_OPTIONAL_LOCKS=0 git -C "$top" status --porcelain=v1 -z -b --untracked-files=all \
        | head -c \(statusByteLimit)
        """)
    }

    /// Diff de un archivo frente a `HEAD` (o, sin commits, índice + árbol de trabajo).
    /// Un archivo sin seguimiento se compara con `/dev/null` (`--no-index` sale con 1).
    static func diff(root: String, change: GitFileChange, hasCommits: Bool) -> String {
        let gitDiff = "\(git(root)) -c core.quotepath=off diff --no-color --no-ext-diff"
        let body: String
        if change.isUntracked {
            body = "\(gitDiff) --no-index -- /dev/null \(q(change.path))"
        } else if hasCommits {
            body = "\(gitDiff) -M HEAD -- \(pathspec(change.affectedPaths))"
        } else {
            body = "\(gitDiff) --cached -- \(q(change.path)); \(gitDiff) -- \(q(change.path))"
        }
        return ShellQuoting.posixShell("{ \(body); } | head -c \(diffByteLimit + 1)")
    }

    /// Descarta los cambios de un archivo: lo deja como en `HEAD` (restore en modo
    /// no-overlay: un archivo que no existe en HEAD se borra) o, si no tenía seguimiento,
    /// lo elimina. Operación destructiva: la UI pide confirmación.
    static func discard(root: String, change: GitFileChange) -> String {
        if change.isUntracked {
            return ShellQuoting.posixShell("\(git(root)) clean -f -- \(q(change.path))")
        }
        return ShellQuoting.posixShell(
            "\(git(root)) restore --source=HEAD --staged --worktree -- \(pathspec(change.affectedPaths))"
        )
    }

    /// Prepara y hace commit SOLO de `changes` (`commit --only` implícito con pathspec),
    /// sin arrastrar lo que ya estuviera en el índice de otros archivos.
    /// `add` recibe solo la ruta actual de cada archivo: el origen de un renombrado ya
    /// preparado (`git mv`) no existe ni en el índice ni en disco y `add` fallaría con
    /// «pathspec did not match». El commit sí lleva ambas rutas (si no, el borrado del
    /// origen quedaría fuera).
    static func commit(root: String, message: String, changes: [GitFileChange]) -> String {
        ShellQuoting.posixShell(commitScript(root: root, message: message, changes: changes))
    }

    /// Script de `commit` sin envolver en `sh -c` (testeable).
    static func commitScript(root: String, message: String, changes: [GitFileChange]) -> String {
        let stage = pathspec(unique(changes.map(\.path)))
        let spec = pathspec(commitPaths(changes))
        return "\(git(root)) add -A -- \(stage) && \(git(root)) commit -m \(q(message)) -- \(spec)"
    }

    /// Rutas del commit (incluye el origen de los renombrados), sin duplicados.
    static func commitPaths(_ changes: [GitFileChange]) -> [String] {
        unique(changes.flatMap(\.affectedPaths))
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Sube la rama. Sin upstream, la publica en `origin` y lo fija (`-u`).
    static func push(root: String, hasUpstream: Bool) -> String {
        let target = hasUpstream ? "" : " -u origin HEAD"
        return ShellQuoting.posixShell("\(nonInteractiveEnv) git -C \(q(root)) push\(target) 2>&1")
    }

    /// Trae cambios solo si se puede avanzar sin merge (nunca deja conflictos a medias).
    static func pull(root: String) -> String {
        ShellQuoting.posixShell("\(nonInteractiveEnv) git -C \(q(root)) pull --ff-only 2>&1")
    }
}
