//
//  GitWorktree.swift
//  ArgosCore
//
//  «Ramas en paralelo»: worktrees de git en el servidor (lógica pura). Cada worktree es
//  una carpeta con su propia rama, así que cada uno puede tener su agente trabajando
//  sin pisar a los demás. En Argos, un worktree es un PROYECTO normal (su carpeta es la
//  del worktree), sin cambiar el formato de `projects.json`.
//

import Foundation

/// Un worktree del repositorio (`git worktree list --porcelain`).
struct GitWorktree: Hashable, Sendable, Identifiable {
    /// Ruta absoluta (la que da git).
    let path: String
    let head: String
    /// `nil` con HEAD desacoplado.
    let branch: String?
    /// El worktree principal (el repositorio original): no se puede quitar.
    let isMain: Bool
    let isLocked: Bool
    /// git cree que su carpeta ya no existe (`git worktree prune` lo limpiaría).
    let isPrunable: Bool
    /// Archivos con cambios sin commit (`nil` si no se pudo saber).
    var changedCount: Int?

    var id: String { path }
    var displayBranch: String { branch ?? "HEAD desacoplado (\(head.prefix(7)))" }
}

/// Worktrees del repositorio y sus ramas locales (para elegir una existente).
struct GitWorktreeListing: Hashable, Sendable {
    let worktrees: [GitWorktree]
    let branches: [String]

    var main: GitWorktree? { worktrees.first(where: \.isMain) }

    /// Ramas que no están ya en algún worktree (git no deja tener la misma en dos).
    var freeBranches: [String] {
        let used = Set(worktrees.compactMap(\.branch))
        return branches.filter { !used.contains($0) }
    }

    /// Carpeta por defecto de un worktree nuevo: hermana del repo, `app-worktrees/rama`.
    func defaultPath(forBranch branch: String) -> String? {
        guard let main else { return nil }
        let parent = (main.path as NSString).deletingLastPathComponent
        let repo = (main.path as NSString).lastPathComponent
        return "\(parent)/\(repo)-worktrees/\(GitBranchName.slug(branch))"
    }
}

/// Reglas de nombre de rama (las de `git check-ref-format --branch`, en lo esencial). El
/// servidor vuelve a comprobarlo con git antes de crear nada.
enum GitBranchName {
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), name != "@", !name.contains(".."),
              !name.contains("//"), !name.contains("@{"), !name.contains("/.")
        else { return false }
        if name.hasPrefix(".") { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters).union(.whitespacesAndNewlines)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) && $0.value != 0x7F }
    }

    /// Nombre para carpetas y proyectos: `feat/login` → `feat-login`.
    static func slug(_ branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// Para el nombre del proyecto (y de su sesión tmux, que no admite «.» ni «:»).
    static func projectSlug(_ branch: String) -> String {
        slug(branch).replacingOccurrences(of: ".", with: "-")
    }
}

/// Petición validada de worktree nuevo.
struct GitWorktreeRequest: Hashable, Sendable {
    /// Raíz de cualquier worktree del repo (desde ella se ejecuta `git worktree`).
    let repository: String
    let branch: String
    /// `true`: crea la rama desde `base`; `false`: usa una rama local existente.
    let createsBranch: Bool
    /// Desde dónde nace la rama nueva (rama, etiqueta o `HEAD`).
    let base: String
    /// Carpeta ABSOLUTA del worktree (no debe existir).
    let path: String

    enum ValidationError: LocalizedError, Equatable {
        case invalidBranch, branchExists, branchInUse, invalidBase, invalidPath

        var errorDescription: String? {
            switch self {
            case .invalidBranch: return "Ese nombre de rama no es válido (sin espacios, «..», «~», «^», «:» ni «-» al principio)."
            case .branchExists: return "Esa rama ya existe: elige «Rama existente» para abrirla."
            case .branchInUse: return "Esa rama ya está abierta en otro worktree: git no deja tenerla en dos a la vez."
            case .invalidBase: return "Elige desde qué rama nace la nueva."
            case .invalidPath: return "La carpeta debe ser una ruta completa que empiece por /."
            }
        }
    }

    static func make(
        listing: GitWorktreeListing, branch: String, createsBranch: Bool, base: String, path: String
    ) throws -> GitWorktreeRequest {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitBranchName.isValid(name) else { throw ValidationError.invalidBranch }
        if createsBranch {
            guard !listing.branches.contains(name) else { throw ValidationError.branchExists }
            guard from == "HEAD" || GitBranchName.isValid(from) else { throw ValidationError.invalidBase }
        } else {
            guard listing.freeBranches.contains(name) else { throw ValidationError.branchInUse }
        }
        guard folder.hasPrefix("/"), !folder.contains("/../"), !folder.hasSuffix("/..") else {
            throw ValidationError.invalidPath
        }
        guard let main = listing.main else { throw ValidationError.invalidPath }
        return GitWorktreeRequest(repository: main.path, branch: name, createsBranch: createsBranch,
                                  base: from, path: folder)
    }
}
