//
//  GitDiffView.swift
//  ArgosUI
//
//  Diff de un archivo (Mac e iPhone/iPad): números de línea antiguos/nuevos, líneas
//  añadidas en verde y eliminadas en rojo, desplazable en ambos ejes. Y la insignia de
//  estado de un archivo cambiado. SwiftUI puro (sin AppKit/UIKit).
//

import SwiftUI

struct GitDiffView: View {
    let diff: GitFileDiff
    var fontSize: CGFloat = 12

    var body: some View {
        if diff.isBinary {
            ContentUnavailableView("Archivo binario", systemImage: "doc.zipper",
                                   description: Text("No se puede mostrar el diff de un archivo binario."))
        } else if !diff.hasContent {
            ContentUnavailableView("Sin diferencias de contenido", systemImage: "equal.circle",
                                   description: Text("Puede que solo hayan cambiado los permisos del archivo."))
        } else {
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(contentLines) { line in
                            GitDiffLineRow(line: line, fontSize: fontSize, numberWidth: numberWidth)
                                .frame(minWidth: proxy.size.width, alignment: .leading)
                        }
                        if diff.truncated {
                            Label("Diff recortado: es demasiado grande para mostrarlo entero.",
                                  systemImage: "scissors")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    /// Las cabeceras `diff --git`/`index`/`---`/`+++` no aportan en un diff de un archivo.
    private var contentLines: [GitDiffLine] {
        diff.lines.filter { $0.kind != .meta }
    }

    private var numberWidth: CGFloat {
        let maxNumber = diff.lines.compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
        let digits = max(3, String(maxNumber).count)
        return CGFloat(digits) * fontSize * 0.62 + 8
    }
}

private struct GitDiffLineRow: View {
    let line: GitDiffLine
    let fontSize: CGFloat
    let numberWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if line.kind == .hunk {
                Text(line.text)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            } else {
                number(line.oldNumber)
                number(line.newNumber)
                Text(sign)
                    .foregroundStyle(signColor)
                    .frame(width: fontSize, alignment: .center)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
                    .padding(.trailing, 12)
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, line.kind == .hunk ? 4 : 0.5)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        default: return .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.14)
        case .hunk: return Color.accentColor.opacity(0.08)
        default: return .clear
        }
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: return "Añadida, línea \(line.newNumber ?? 0): \(line.text)"
        case .removed: return "Eliminada, línea \(line.oldNumber ?? 0): \(line.text)"
        case .hunk: return "Bloque \(line.text)"
        default: return line.text
        }
    }
}

/// Letra de estado de un archivo cambiado, con color (y forma: la letra, no solo el color).
struct GitChangeBadge: View {
    let kind: GitChangeKind

    var body: some View {
        Text(kind.letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .help(kind.label)
            .accessibilityLabel(kind.label)
    }

    private var color: Color {
        switch kind {
        case .modified, .typeChanged: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .conflicted: return .purple
        }
    }
}

/// Resumen `+N −M` de un diff.
struct GitDiffStat: View {
    let diff: GitFileDiff

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(diff.additions)").foregroundStyle(.green)
            Text("−\(diff.deletions)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(diff.additions) líneas añadidas, \(diff.deletions) eliminadas")
    }
}
