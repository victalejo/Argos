//
//  Checkpoint.swift
//  ArgosCore
//
//  Puntos de restauración por turno (lógica pura): un punto es un commit suelto en el
//  repositorio aparte `<gitdir>/argos-checkpoints.git` (`refs/checkpoints/<epoch>`) con el
//  contenido del árbol de trabajo justo cuando el usuario envió un mensaje a Claude. Lo
//  crea `CheckpointScript`.
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
    /// `HEAD` cuando se creó (`nil` en un repo sin commits). Va en `Argos-Head:`: los
    /// puntos son commits sin padre para no depender de la historia del principal.
    let parent: String?
    let date: Date
    let kind: CheckpointKind
    let sessionID: String?
    /// Extracto del mensaje del usuario (una línea) o descripción del punto.
    let label: String
    /// Archivos que cambian hasta el punto siguiente (o hasta ahora, en el más reciente).
    /// `nil` si no se pudo calcular.
    let changedFiles: Int?
    /// Le faltan objetos (p. ej. un `gc` del principal antes de sellarlo): no se restaura.
    var isDamaged: Bool = false

    var id: String { ref }

    var title: String {
        switch kind {
        case .prompt, .unknown, .manual: return label.isEmpty ? "(sin mensaje)" : label
        case .restore: return label
        }
    }
}

struct CheckpointListing: Sendable, Equatable {
    let root: String
    /// `git config argos.checkpoints true`: el hook captura en este repositorio.
    let isEnabled: Bool
    /// `git config argos.checkpointsPrompt true`: se guarda un extracto de cada mensaje.
    let storesPrompts: Bool
    /// El repositorio usa Git LFS: no se capturan puntos.
    var usesLFS: Bool = false
    let headCommit: String?
    /// Del más reciente al más antiguo.
    let checkpoints: [Checkpoint]
    /// Mensajes cuyo punto no se guardó (repo enorme, archivo grande, plazo agotado…).
    let skips: [CheckpointSkip]
    /// Por qué no se pudo comparar con el estado actual (si pasó).
    let currentSkipReason: String?

    /// Omisiones durante el turno del punto `index` (hasta el siguiente punto o ahora).
    func skips(duringTurnAt index: Int) -> [CheckpointSkip] {
        guard checkpoints.indices.contains(index) else { return [] }
        let start = checkpoints[index].date
        let end = index > 0 ? checkpoints[index - 1].date : .distantFuture
        return skips.filter { $0.date >= start && $0.date < end }
    }
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

/// Algo que impide escribir una ruta (o que se deja sin tocar) al restaurar.
struct CheckpointIssue: Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        /// Hoy es una carpeta donde el punto tenía un archivo.
        case directoryInTheWay = "D"
        /// Hay un repositorio git anidado en el camino.
        case nestedRepository = "R"
        /// En el camino hay un archivo o enlace que no está en la copia (p. ej. ignorado).
        case blockedPath = "F"
        /// Falta el contenido en el punto (objetos borrados).
        case missingContent = "M"
        /// Su contenido en disco no coincide con la copia previa: no se toca nada.
        case changedOnDisk = "C"
        /// Sus permisos (p. ej. 0600) no se guardan en la copia.
        case permissions = "P"
        /// No se pudo escribir o borrar al restaurar.
        case writeFailed = "E"
        /// Existe y no está en la copia (p. ej. ignorado por git): no se toca.
        case unprotected = "I"
        /// Repositorio anidado: no se toca.
        case nestedUntouched = "N"
    }

    let kind: Kind
    let path: String

    /// Bloquea la restauración entera (el resto solo se salta).
    var isConflict: Bool { kind != .unprotected && kind != .nestedUntouched }

    var explanation: String {
        switch kind {
        case .directoryInTheWay: return "hoy es una carpeta"
        case .nestedRepository: return "está dentro de un repositorio git anidado"
        case .blockedPath: return "en su camino hay un archivo o enlace que git ignora"
        case .missingContent: return "falta su contenido en el punto"
        case .changedOnDisk: return "cambió y la copia previa no lo tiene"
        case .permissions: return "tiene permisos restringidos que la copia no guarda"
        case .writeFailed: return "no se pudo escribir o borrar"
        case .unprotected: return "existe y git lo ignora: no se toca"
        case .nestedUntouched: return "es un repositorio anidado: no se toca"
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
    /// Rutas con problemas: los conflictos bloquean; las «sin proteger» se saltan.
    let issues: [CheckpointIssue]

    var conflicts: [CheckpointIssue] { issues.filter(\.isConflict) }
    var untouched: [String] { issues.filter { !$0.isConflict }.map(\.path) }
    var canRestore: Bool { conflicts.isEmpty }
    var isEmpty: Bool { toModify.isEmpty && toDelete.isEmpty && toRecreate.isEmpty }

    /// Lo que de verdad se hará: sin lo que se deja como está.
    var modifies: [String] { toModify.filter { !untouched.contains($0) } }
    var deletes: [String] { toDelete.filter { !untouched.contains($0) } }
    var recreates: [String] { toRecreate.filter { !untouched.contains($0) } }
}

enum CheckpointPreviewResult: Sendable, Equatable {
    case ready(CheckpointRestorePreview)
    /// Hacer la copia del estado actual costaría mucho (lo que el hook rechazó): se pregunta.
    case heavy(String)
}

enum CheckpointRestoreOutcome: Sendable, Equatable {
    /// Hecho; `backup` es el punto creado (o reutilizado) con el estado anterior.
    case done(backup: String?)
    /// Se restauró, pero el árbol no quedó idéntico (p. ej. quedan archivos ignorados o
    /// alguno cambió durante la restauración y no se tocó).
    case partial(backup: String?, skipped: [CheckpointIssue])
    /// Los archivos cambiaron desde la vista previa: no se tocó nada.
    case changed
    /// Hay rutas que no se pueden escribir sin perder datos: no se tocó nada.
    case conflict([CheckpointIssue])
    /// No había nada que hacer (ruta no válida, ignorada o ausente).
    case nothing(String)
}

enum CheckpointError: LocalizedError, Equatable {
    case busy(String)
    case badReference
    case failed(String)
    case unexpectedOutput(String)
    case unavailable
    /// Al punto le faltan objetos.
    case damaged
    /// git del servidor anterior a 2.20.
    case gitTooOld
    /// Comparar con el estado actual costaría mucho.
    case heavy(String)

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
        case .damaged:
            return "A este punto le faltan datos (git los borró antes de guardarlos aparte). No se puede restaurar."
        case .gitTooOld:
            return "Los puntos de restauración necesitan git 2.20 o posterior en el servidor."
        case .heavy(let reason):
            return "Comparar con el estado actual costaría mucho (\(reason)). Compara entre puntos o ignora esos archivos en git."
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
