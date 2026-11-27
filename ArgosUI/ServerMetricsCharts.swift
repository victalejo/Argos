//
//  ServerMetricsCharts.swift
//  ArgosUI
//
//  Gráficas del historial de recursos: memoria y swap (%), CPU (%), carga y memoria de
//  Claude, todas con las marcas de OOM como líneas rojas verticales. Cuerpos pequeños y
//  tipos explícitos: la CI compila con Swift 6.1.
//

import Charts
import SwiftUI

/// Un valor de una serie (lo que pinta cada `LineMark`).
private struct MetricValue: Identifiable {
    let date: Date
    let series: String
    let value: Double

    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

struct MetricsCharts: View {
    let points: [ServerMetricsPoint]
    let marks: [ServerOOMMark]
    let range: ServerMetricsRange

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !marks.isEmpty { oomSummary }
            MetricChart(title: String(localized: "Memoria y swap usadas"), unit: "%",
                        values: memoryValues, marks: marks, percent: true)
            MetricChart(title: String(localized: "CPU"), unit: "%", values: cpuValues, marks: marks, percent: true)
            MetricChart(title: String(localized: "Carga"), unit: "", values: loadValues, marks: marks, percent: false)
            MetricChart(title: String(localized: "Memoria de Claude (GB)"), unit: "GB",
                        values: claudeValues, marks: marks, percent: false)
            if range.usesAggregates {
                Text("En 7 días cada punto es un tramo de 10 min: memoria con su peor valor, CPU media y picos de carga y de Claude.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var oomSummary: some View {
        let count = marks.count
        let text: String = marks.last.map { last in
            let when = last.date.formatted(date: .abbreviated, time: .shortened)
            let process = last.process
            return String(localized: "Sin memoria en este periodo: \(count). La última, \(when) (cerró \(process)).")
        } ?? ""
        return Label(text, systemImage: "exclamationmark.octagon")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var memoryValues: [MetricValue] {
        let memory = String(localized: "Memoria")
        let swap = String(localized: "Swap")
        return points.flatMap { point -> [MetricValue] in
            var values = [MetricValue(date: point.date, series: memory, value: point.memoryUsedFraction * 100)]
            if let used = point.swapUsedFraction {
                values.append(MetricValue(date: point.date, series: swap, value: used * 100))
            }
            return values
        }
    }

    private var cpuValues: [MetricValue] {
        let name = String(localized: "CPU")
        return points.compactMap { point in point.cpu.map { MetricValue(date: point.date, series: name, value: $0 * 100) } }
    }

    private var loadValues: [MetricValue] {
        let name = String(localized: "Carga")
        return points.compactMap { point in point.load.map { MetricValue(date: point.date, series: name, value: $0) } }
    }

    private var claudeValues: [MetricValue] {
        let name = String(localized: "Claude")
        return points.compactMap { point in
            point.claudeRSSKB.map { MetricValue(date: point.date, series: name, value: Double($0) / 1_048_576) }
        }
    }
}

private struct MetricChart: View {
    let title: String
    let unit: String
    let values: [MetricValue]
    let marks: [ServerOOMMark]
    let percent: Bool

    private var seriesCount: Int { Set(values.map(\.series)).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let latest = latestText { Text(latest).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if values.isEmpty {
                Text("Sin datos").font(.caption).foregroundStyle(.tertiary).frame(height: 40)
            } else {
                chart.frame(height: 110)
            }
        }
    }

    private var latestText: String? {
        guard let last = values.last else { return nil }
        let number = last.value.formatted(.number.precision(.fractionLength(percent ? 0 : 1)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    private var chart: some View {
        Chart {
            ForEach(values) { value in
                LineMark(
                    x: .value("Hora", value.date),
                    y: .value(title, value.value),
                    series: .value("Serie", value.series)
                )
                .foregroundStyle(by: .value("Serie", value.series))
                .interpolationMethod(.monotone)
            }
            ForEach(marks) { mark in
                RuleMark(x: .value("OOM", mark.date))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .chartYScale(domain: yDomain)
        .chartLegend(seriesCount > 1 ? .visible : .hidden)
    }

    private var yDomain: ClosedRange<Double> {
        if percent { return 0...100 }
        let top = values.map(\.value).max() ?? 1
        return 0...max(top * 1.1, 0.1)
    }
}
