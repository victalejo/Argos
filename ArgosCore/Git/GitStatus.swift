//
//  GitStatus.swift
//  ArgosCore
//
//  Estado de un repositorio git del servidor (lógica pura): rama, upstream,
//  adelantado/atrasado y archivos cambiados. Lo parsea `GitStatusParser` a partir de
//  `git status --porcelain=v1 -z -b`.
//

import Foundation

/// Tipo de cambio de un archivo en el índice o en el árbol de trabajo.
enum GitChangeKind: String, Sendable, Hashable {
    case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted

    /// Letra corta para la UI (como en `git status -s`).
    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    /// Descripción para VoiceOver y tooltips.
    var label: String {
        switch self {
        case .modified: return "Modificado"
        case .added: return "Añadido"
        case .deleted: return "Eliminado"
        case .renamed: return "Renombrado"
        case .copied: return "Copiado"
        case .typeChanged: return "Tipo cambiado"
        case .untracked: return "Nuevo, sin seguimiento"
        case .conflicted: return "En conflicto"
        }
    }
}

/// Un archivo con cambios respecto a `HEAD`.
struct GitFileChange: Identifiable, Hashable, Sendable {
    /// Ruta relativa a la raíz del repositorio.
    let path: String
    /// Ruta anterior en un renombrado/copia.
    let originalPath: String?
    /// Columna X de porcelain (índice) e Y (árbol de trabajo), tal cual.
    let indexCode: Character
    let worktreeCode: Character

    var id: String { path }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir
    }

    var isUntracked: Bool { indexCode == "?" && worktreeCode == "?" }

    /// Combinaciones de conflicto de `git status` (DD, AU, UD, UA, DU, AA, UU).
    var isConflicted: Bool {
        let pair = String([indexCode, worktreeCode])
        return ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair)
    }

    /// Tipo de cambio dominante para mostrar (el del índice si lo hay; si no, el del árbol).
    var kind: GitChangeKind {
        if isUntracked { return .untracked }
        if isConflicted { return .conflicted }
        return Self.kind(for: indexCode) ?? Self.kind(for: worktreeCode) ?? .modified
    }

    /// Rutas que afectan a un commit o a un descarte (incluye el origen de un renombrado).
    var affectedPaths: [String] {
        [originalPath, path].compactMap { $0 }
    }

    private static func kind(for code: Character) -> GitChangeKind? {
        switch code {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return nil
        }
    }
}

/// Rama actual y su relación con el upstream.
struct GitBranchInfo: Hashable, Sendable {
    /// `nil` con HEAD desacoplado.
    let name: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    /// `false` en un repositorio recién creado sin commits.
    let hasCommits: Bool
    /// El upstream configurado ya no existe en el remoto.
    let upstreamGone: Bool

    static let unknown = GitBranchInfo(
        name: nil, upstream: nil, ahead: 0, behind: 0, hasCommits: true, upstreamGone: false
    )
}

/// Estado completo de un repositorio.
struct GitRepositoryStatus: Hashable, Sendable {
    /// Raíz absoluta del repositorio en el servidor (`git rev-parse --show-toplevel`).
    let root: String
    let branch: GitBranchInfo
    let changes: [GitFileChange]
    /// Se recortó la lista (demasiados archivos, p. ej. un `node_modules` sin ignorar).
    let truncated: Bool

    var repositoryName: String { (root as NSString).lastPathComponent }
    var isClean: Bool { changes.isEmpty }
}

/// Resultado de consultar el estado git de una carpeta.
enum GitStatusResult: Hashable, Sendable {
    case gitMissing
    case notRepository
    case repository(GitRepositoryStatus)
}
