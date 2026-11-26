//
//  ClaudeUsageView.swift
//  ArgosUI
//
//  Uso de tokens de Claude en un servidor (Mac e iPhone/iPad): totales del periodo, coste
//  equivalente en la API, gráfica por día y desglose por proyecto y por modelo.
//

import Charts
import SwiftUI

struct ClaudeUsageView: View {
    @Bindable var model: ClaudeUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Periodo", selection: $model.range) {
                ForEach(ClaudeUsageRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            content
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .indexing:
            indexingNotice
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Reintentar") { Task { await model.load(force: true) } }
            }
        case .ready:
            if let summary = model.summary() {
                ClaudeUsageSummaryView(summary: summary, range: model.range, isUpdating: model.isUpdating)
            }
        }
    }

    private var indexingNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Calculando el uso en el servidor a partir del historial de Claude Code. La primera vez puede tardar unos minutos; las siguientes, segundos.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ClaudeUsageSummaryView: View {
    let summary: ClaudeUsageSummary
    let range: ClaudeUsageRange
    let isUpdating: Bool

    private static let visibleProjects = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            totals
            if range != .today {
                ClaudeUsageChart(days: summary.days)
            }
            breakdown(title: "Por proyecto", lines: Array(summary.projects.prefix(Self.visibleProjects)))
            if summary.projects.count > Self.visibleProjects {
                Text("y \(summary.projects.count - Self.visibleProjects) proyectos más")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            breakdown(title: "Por modelo", lines: summary.models)
            Text("Coste equivalente en precios de la API de Anthropic. Con una suscripción no pagas por token: sirve para comparar proyectos y días.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var totals: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.cost, format: .currency(code: "USD"))
                    .font(.title2.weight(.semibold).monospacedDigit())
                Text("coste equivalente").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.tokens.total, format: .number.notation(.compactName))
                    .font(.title3.monospacedDigit())
                Text("tokens").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.requests, format: .number)
                    .font(.title3.monospacedDigit())
                Text("respuestas").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isUpdating {
                ProgressView().controlSize(.small).help(Text("Actualizando"))
            }
        }
    }

    @ViewBuilder
    private func breakdown(title: LocalizedStringKey, lines: [ClaudeUsageLine]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(lines) { line in
                    ClaudeUsageLineRow(line: line, maxCost: lines.first?.cost ?? 0)
                }
            }
        }
    }
}

private struct ClaudeUsageLineRow: View {
    let line: ClaudeUsageLine
    let maxCost: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(line.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(line.cost, format: .currency(code: "USD"))
                    .font(.callout.monospacedDigit())
            }
            HStack(spacing: 8) {
                ProgressView(value: maxCost > 0 ? line.cost / maxCost : 0)
                    .progressViewStyle(.linear)
                Text(line.tokens.total, format: .number.notation(.compactName))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ClaudeUsageChart: View {
    let days: [ClaudeUsageDay]

    var body: some View {
        Chart(days) { (day: ClaudeUsageDay) in
            BarMark(
                x: .value("Día", day.day, unit: .day),
                y: .value("Coste", day.cost)
            )
            .foregroundStyle(Color.accentColor.gradient)
        }
        .chartYAxis {
            AxisMarks { (value: AxisValue) in
                AxisGridLine()
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(cost, format: .currency(code: "USD").precision(.fractionLength(0)))
                    }
                }
            }
        }
        .frame(height: 140)
        .accessibilityLabel(Text("Coste por día"))
    }
}
