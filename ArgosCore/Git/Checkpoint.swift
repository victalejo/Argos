//
//  Checkpoint.swift
//  ArgosCore
//
//  Puntos de restauración por turno (lógica pura): un punto es un commit suelto bajo
//  `refs/argos/checkpoints/<worktree>/<epoch>` con el contenido del árbol de trabajo
//  justo cuando el usuario envió un mensaje a Claude. Lo crea `CheckpointScript`.
//

import Foundation

/// Quién creó el punto.
enum CheckpointKind: String, Sendable, Hashable {
    /// El hook de Claude, al enviar un mensaje.
    case prompt
    /// Copia automática del estado justo antes de restaurar otro punto.
    case restore
    /// Creado a mano desde la app.
    case manual
    case unknown
}

struct Checkpoint: Identifiable, Hashable, Sendable {
    let ref: String
    let commit: String
    /// `HEAD` cuando se creó (`nil` en un repo sin commits).
    let parent: String?
    let date: Date
    let kind: CheckpointKind
    let sessionID: String?
    /// Extracto del mensaje del usuario (una línea) o descripción del punto.
    let label: String
    /// Archivos que cambian hasta el punto siguiente (o hasta ahora, en el más reciente).
    /// `nil` si no se pudo calcular.
    let changedFiles: Int?

    var id: String { ref }

    var title: String {
        switch kind {
        case .prompt, .unknown, .manual: return label.isEmpty ? "(sin mensaje)" : label
        case .restore: return label
        }
    }
}

/// ¿Se capturan puntos en este repositorio?
enum CheckpointCaptureState: String, Sendable, Equatable {
    case on
    /// `~/.config/argos/checkpoints-off` existe en el servidor.
    case offServer = "off-server"
    /// `git config argos.checkpoints false` en el repositorio.
    case offRepo = "off-repo"
}

struct CheckpointListing: Sendable, Equatable {
    let root: String
    let state: CheckpointCaptureState
    let headCommit: String?
    /// Del más reciente al más antiguo.
    let checkpoints: [Checkpoint]
    /// Último intento del hook que se omitió (repo enorme, archivo grande…).
    let lastSkip: CheckpointSkip?
    /// Por qué no se pudo comparar con el estado actual (si pasó).
    let currentSkipReason: String?
}

struct CheckpointSkip: Sendable, Equatable {
    let date: Date
    let reason: String
}

enum CheckpointListResult: Sendable, Equatable {
    case gitMissing
    case notRepository
    case listing(CheckpointListing)
}

/// Archivo que difiere entre dos estados (de `from` a `to`).
struct CheckpointFileChange: Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable { case added, deleted, modified, typeChanged }

    let path: String
    let kind: Kind

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    /// Para reutilizar la insignia del panel «Cambios».
    var gitKind: GitChangeKind {
        switch kind {
        case .added: return .added
        case .deleted: return .deleted
        case .modified: return .modified
        case .typeChanged: return .typeChanged
        }
    }
}

/// Qué pasará al restaurar un punto (para la confirmación).
struct CheckpointRestorePreview: Sendable, Equatable {
    let checkpoint: Checkpoint
    /// Árbol actual visto: si cambia antes de confirmar, la restauración se detiene.
    let currentTree: String
    let toModify: [String]
    /// Archivos que no existían en el punto (nunca incluye los ignorados por git).
    let toDelete: [String]
    /// Archivos que existían en el punto y ya no.
    let toRecreate: [String]
    /// Commits hechos desde el punto (la rama no se mueve: solo se restauran archivos).
    let commitsSince: Int

    var isEmpty: Bool { toModify.isEmpty && toDelete.isEmpty && toRecreate.isEmpty }
}

enum CheckpointRestoreOutcome: Sendable, Equatable {
    /// Hecho; `backup` es el punto creado (o reutilizado) con el estado anterior.
    case done(backup: String?)
    /// Se restauró, pero el árbol no quedó idéntico (p. ej. quedan archivos ignorados).
    case partial(backup: String?)
    /// Los archivos cambiaron desde la vista previa: no se tocó nada.
    case changed
}

enum CheckpointError: LocalizedError, Equatable {
    case busy(String)
    case badReference
    case failed(String)
    case unexpectedOutput(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .busy(let operation):
            return "Hay una operación de git a medias (\(Self.describe(operation))). "
                + "Termínala o cancélala en el terminal antes de restaurar."
        case .badReference:
            return "Ese punto de restauración ya no existe en el servidor. Recarga la lista."
        case .failed(let detail):
            return "No se pudo completar en el servidor: \(detail)."
        case .unexpectedOutput(let detail):
            return detail.isEmpty
                ? "El servidor no respondió como se esperaba. Vuelve a intentarlo."
                : detail
        case .unavailable:
            return "Los puntos de restauración no están disponibles en esta conexión."
        }
    }

    static func describe(_ operation: String) -> String {
        switch operation {
        case "rebase-merge", "rebase-apply": return "rebase"
        case "MERGE_HEAD": return "merge"
        case "CHERRY_PICK_HEAD": return "cherry-pick"
        case "REVERT_HEAD": return "revert"
        case "BISECT_LOG": return "bisect"
        default: return operation
        }
    }
}

/// Salida cruda de un comando de puntos de restauración.
struct CheckpointCommandOutput: Sendable, Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int
}
