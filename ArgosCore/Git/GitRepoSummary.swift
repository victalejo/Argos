//
//  GitRepoSummary.swift
//  ArgosCore
//
//  Resumen git de VARIOS proyectos en un solo round-trip SSH (lógica pura): rama,
//  adelantado/atrasado y cuántos archivos cambiados. Lo usa la lista de proyectos
//  (insignia ↑2 ✎5) y el aviso «Claude terminó · N archivos cambiados».
//

import Foundation

/// Estado git resumido de una carpeta.
struct GitRepoSummary: Hashable, Sendable {
    let branch: GitBranchInfo
    /// Archivos con cambios (las carpetas sin seguimiento cuentan como una entrada).
    let changedCount: Int

    var isClean: Bool { changedCount == 0 }
    /// Hay algo que mostrar en la fila (cambios o commits por subir/bajar).
    var isNoteworthy: Bool { changedCount > 0 || branch.ahead > 0 || branch.behind > 0 }

    /// Texto corto para tooltips y VoiceOver («rama main, 5 archivos cambiados, 2 por subir»).
    var label: String {
        var parts = ["rama \(branch.name ?? "HEAD desacoplado")"]
        if changedCount > 0 {
            parts.append("\(changedCount) archivo\(changedCount == 1 ? "" : "s") cambiado\(changedCount == 1 ? "" : "s")")
        }
        if branch.ahead > 0 { parts.append("\(branch.ahead) commit\(branch.ahead == 1 ? "" : "s") por subir") }
        if branch.behind > 0 { parts.append("\(branch.behind) commit\(branch.behind == 1 ? "" : "s") por traer") }
        if !isNoteworthy { parts.append("sin cambios") }
        return parts.joined(separator: ", ")
    }
}

enum GitSummaryCommands {

    /// Prefijo de cada línea de resultado (el perfil del shell puede ensuciar la salida).
    static let marker = "ARGOS_GSUM"
    /// Segundos máximos por repositorio (un repo enorme no bloquea a los demás).
    static let perRepoTimeout = 5

    /// Una línea por ruta: `ARGOS_GSUM <i> <n> <cabecera -b>` o `ARGOS_GSUM <i> -` si no
    /// es un repositorio. `GIT_OPTIONAL_LOCKS=0`: no toma el lock del índice (un agente
    /// puede estar haciendo commits). Las carpetas sin seguimiento no se expanden
    /// (`--untracked-files=normal`): basta para contar y es mucho más barato.
    static func summaries(paths: [String]) -> String {
        let list = paths.map(ShellQuoting.singleQuoted).joined(separator: " ")
        return ShellQuoting.posixShell("""
        command -v git >/dev/null 2>&1 || exit 0
        t=''; command -v timeout >/dev/null 2>&1 && t='timeout \(perRepoTimeout)'
        i=0
        for p in \(list); do
          out=$(GIT_OPTIONAL_LOCKS=0 $t git -C "$p" status --porcelain=v1 -b --untracked-files=normal 2>/dev/null) \
            || { printf '%s %s -\\n' \(marker) "$i"; i=$((i+1)); continue; }
          n=$(printf '%s\\n' "$out" | sed 1d | grep -c .)
          h=$(printf '%s\\n' "$out" | sed -n 1p)
          printf '%s %s %s %s\\n' \(marker) "$i" "$n" "$h"
          i=$((i+1))
        done
        """)
    }
}

enum GitSummaryParser {

    /// Resúmenes por ruta (las que no son repositorio no aparecen).
    static func parse(_ output: String, paths: [String]) -> [String: GitRepoSummary] {
        var result: [String: GitRepoSummary] = [:]
        let prefix = GitSummaryCommands.marker + " "
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            let fields = line.dropFirst(prefix.count).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let index = Int(fields[0]), paths.indices.contains(index),
                  let count = Int(fields[1])
            else { continue }
            let header = String(fields[2])
            guard header.hasPrefix("## ") else { continue }
            result[paths[index]] = GitRepoSummary(
                branch: GitStatusParser.parseBranch(String(header.dropFirst(3))),
                changedCount: count
            )
        }
        return result
    }
}

/// Texto del aviso «Claude terminó» (Mac e iPhone/iPad), con los archivos cambiados
/// del proyecto si se conocen: así se sabe de un vistazo si hay algo que revisar.
enum ClaudeDoneMessage {
    static func body(changedFiles: Int?) -> String {
        guard let changedFiles, changedFiles > 0 else { return "Terminó de responder." }
        let files = "\(changedFiles) archivo\(changedFiles == 1 ? "" : "s") cambiado\(changedFiles == 1 ? "" : "s")"
        return "Terminó de responder · \(files). Revísalos en «Cambios»."
    }
}
