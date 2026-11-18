//
//  CheckpointTexts.swift
//  ArgosCore
//
//  Textos de la interfaz de los puntos de restauración, comunes a Mac e iPhone/iPad
//  (lógica pura, sin SwiftUI).
//

import Foundation

enum CheckpointTexts {

    /// Rutas que se enumeran en la confirmación por sección (el resto, «y N más»).
    static let maxListedPaths = 200

    static let restoreFootnote = "Antes se guarda un punto con el estado actual, así que se puede deshacer. "
        + "Los archivos ignorados por git (.env, node_modules…) y los repositorios anidados nunca se tocan, "
        + "y la rama y los commits no se mueven."

    static let restoreFileMessage = "Queda como se ve en «Hasta ahora»: como estaba en este punto, o se borra si "
        + "entonces no existía. Antes se guarda un punto con el estado actual."

    static let restoreFileOnlySinceThen = "Para restaurar un archivo, compara «Hasta ahora»: es exactamente lo que se deshará."

    static let workingWarning = "Claude está trabajando en este proyecto: no se restaura mientras pueda seguir "
        + "cambiando archivos. Espera a que termine o detenlo."

    static let stopAndRestore = "Detener a Claude y restaurar"

    static let enableFootnote = "Guarda una instantánea del proyecto cada vez que envías un mensaje a Claude Code, "
        + "en una carpeta privada dentro de .git que no viaja con push ni con «Enviar al Mac». "
        + "Al activarlo por primera vez se instala un hook en ~/.claude/settings.json del servidor."

    static let promptsFootnote = "Si está desactivado, cada punto se etiqueta solo con su número de turno y la fecha."

    static func restoreFileTitle(_ path: String) -> String {
        "¿Restaurar «\((path as NSString).lastPathComponent)» como estaba en este punto?"
    }

    static func emptyDescription(_ listing: CheckpointListing) -> String {
        guard listing.isEnabled else {
            return "Están desactivados en este proyecto. Actívalos para guardar un punto cada vez que envíes "
                + "un mensaje a Claude Code y poder deshacer un turno."
        }
        return "Se crean solos cada vez que envías un mensaje a Claude Code en este proyecto. "
            + "También puedes crear uno ahora."
    }

    /// Aviso de la lista (omisiones recientes), o `nil`.
    static func warning(_ listing: CheckpointListing) -> String? {
        guard let skip = listing.skips.last else { return nil }
        if let newest = listing.checkpoints.first, skip.date < newest.date { return nil }
        return "El último mensaje no se guardó: \(skip.reason)."
    }

    /// Omisiones dentro de un turno (entre dos puntos).
    static func skipsText(_ skips: [CheckpointSkip]) -> String? {
        guard let last = skips.last else { return nil }
        let count = skips.count == 1 ? "1 mensaje no se guardó" : "\(skips.count) mensajes no se guardaron"
        return "En este turno \(count) (\(last.reason)): el diff puede incluir varios mensajes."
    }

    static func conflictMessage(_ issues: [CheckpointIssue]) -> String {
        let listed = issues.prefix(5).map { "«\($0.path)» \($0.explanation)" }.joined(separator: "; ")
        let more = issues.count > 5 ? " y \(issues.count - 5) más" : ""
        return "No se restauró nada para no perder datos: \(listed)\(more). Muévelos o resuélvelos a mano y vuelve a intentarlo."
    }

    static func partialMessage(_ skipped: [CheckpointIssue]) -> String {
        let listed = skipped.filter(\.isConflict).prefix(5).map { "«\($0.path)» \($0.explanation)" }.joined(separator: "; ")
        return "Restaurado en parte. No se tocaron: \(listed). La copia previa tiene el estado anterior."
    }

    static func heavyMessage(_ reason: String) -> String {
        "Para poder deshacer la restauración hay que guardar antes el estado actual, y eso costará "
            + "(\(reason)). Puede tardar y ocupar espacio en el servidor."
    }

    static func symbol(_ kind: CheckpointKind) -> String {
        switch kind {
        case .prompt, .unknown: return "text.bubble"
        case .restore: return "arrow.uturn.backward.circle"
        case .manual: return "bookmark"
        }
    }

    static func subtitle(_ checkpoint: Checkpoint, now: Date = Date()) -> String {
        let when = RelativeDateTimeFormatter().localizedString(for: checkpoint.date, relativeTo: now)
        guard let count = checkpoint.changedFiles else { return when }
        let files = count == 1 ? "1 archivo" : "\(count) archivos"
        return "\(when) · \(files)"
    }

    static func commitsWarning(_ preview: CheckpointRestorePreview) -> String? {
        guard preview.commitsSince > 0 else { return nil }
        let commits = preview.commitsSince == 1 ? "se hizo 1 commit" : "se hicieron \(preview.commitsSince) commits"
        return "Desde este punto \(commits). La rama no se moverá: solo cambian los archivos."
    }
}
