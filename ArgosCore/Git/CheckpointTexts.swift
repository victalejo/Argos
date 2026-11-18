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
        + "Los archivos ignorados por git (.env, node_modules…) nunca se tocan, y la rama y los commits no se mueven."

    static let restoreFileMessage = "Queda como estaba en este punto, o se borra si entonces no existía. "
        + "Antes se guarda un punto con el estado actual."

    static func restoreFileTitle(_ path: String) -> String {
        "¿Restaurar «\((path as NSString).lastPathComponent)» como estaba en este punto?"
    }

    static func emptyDescription(_ listing: CheckpointListing) -> String {
        switch listing.state {
        case .offServer:
            return "Están desactivados en este servidor. Actívalos con el interruptor de arriba."
        case .offRepo:
            return "Este repositorio los tiene desactivados (git config argos.checkpoints false)."
        case .on:
            return "Se crean solos cada vez que envías un mensaje a Claude Code en este proyecto, "
                + "si el indicador de Claude está activado en el servidor (ajustes del servidor). "
                + "También puedes crear uno ahora."
        }
    }

    /// Aviso de la lista (captura desactivada u omitida), o `nil`.
    static func warning(_ listing: CheckpointListing) -> String? {
        switch listing.state {
        case .offServer: return "Desactivados en este servidor: no se crean puntos nuevos."
        case .offRepo: return "Desactivados en este repositorio (git config argos.checkpoints)."
        case .on: break
        }
        if let skip = listing.lastSkip {
            return "El último turno no se guardó: \(skip.reason)."
        }
        return nil
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
