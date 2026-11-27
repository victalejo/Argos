//
//  ClaudeTaskReviewView.swift
//  ArgosUI
//
//  Informe del revisor automático de un encargo bloqueado (Mac e iPhone/iPad): resumen,
//  hallazgos con su severidad (icono Y texto) y las dos salidas: «Subir igualmente» y
//  «Pedir a Claude que lo arregle».
//

import SwiftUI

struct ClaudeTaskReviewView: View {
    let task: ClaudeTask
    let isWorking: Bool
    let onPushAnyway: () -> Void
    let onFix: () -> Void

    @State private var confirmsPush = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            findings
            actions
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .confirmationDialog("¿Subir sin la aprobación del revisor?", isPresented: $confirmsPush, titleVisibility: .visible) {
            Button("Subir igualmente", role: .destructive, action: onPushAnyway)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se hará el push que faltaba tal como está el commit, con los hallazgos sin corregir.")
        }
    }

    @ViewBuilder
    private var header: some View {
        Label("Informe del revisor", systemImage: "checkmark.shield")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        if let cause = task.review?.causeText ?? (task.review == nil ? defaultCause : nil) {
            Text(cause).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        if task.review?.truncated == true {
            Text("El informe es demasiado largo para la app: está completo en review.md, en la carpeta del encargo en el servidor.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let summary = task.review?.summary, !summary.isEmpty {
            Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultCause: String? {
        task.reason == .reviewInconclusive ? String(localized: "La revisión no fue concluyente.") : nil
    }

    @ViewBuilder
    private var findings: some View {
        let list: [ClaudeTaskReview.Finding] = task.review?.sortedFindings ?? []
        ForEach(list) { (finding: ClaudeTaskReview.Finding) in
            ClaudeTaskFindingRow(finding: finding)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Pedir a Claude que lo arregle", action: onFix)
                .buttonStyle(.borderedProminent)
            Button("Subir igualmente") { confirmsPush = true }
                .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .disabled(isWorking)
    }
}

private struct ClaudeTaskFindingRow: View {
    let finding: ClaudeTaskReview.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.caption.weight(.semibold))
                Text(finding.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var heading: String {
        let severity = finding.severity?.label ?? String(localized: "Sin severidad")
        guard let location = finding.location else { return severity }
        return "\(severity) · \(location)"
    }

    private var symbol: String {
        switch finding.severity {
        case .critical, .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low, .none: return "info.circle"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low, .none: return .secondary
        }
    }
}
