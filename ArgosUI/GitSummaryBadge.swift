//
//  GitSummaryBadge.swift
//  ArgosUI
//
//  Insignia compacta del estado git de un proyecto en su fila (Mac e iPhone/iPad):
//  `✎5` archivos cambiados, `↑2` commits por subir, `↓3` por traer. No se pinta si el
//  repo está limpio y al día (la fila no se llena de ruido). SwiftUI puro.
//

import SwiftUI

struct GitSummaryBadge: View {
    let summary: GitRepoSummary

    var body: some View {
        if summary.isNoteworthy {
            HStack(spacing: 4) {
                if summary.changedCount > 0 {
                    Text("✎\(summary.changedCount)").foregroundStyle(.orange)
                }
                if summary.branch.ahead > 0 {
                    Text("↑\(summary.branch.ahead)").foregroundStyle(.blue)
                }
                if summary.branch.behind > 0 {
                    Text("↓\(summary.branch.behind)").foregroundStyle(.purple)
                }
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .help(String(summary.label.prefix(1)).uppercased() + String(summary.label.dropFirst()))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Git: \(summary.label)")
        }
    }
}
