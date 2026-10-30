//
//  ServerResourcesView.swift
//  Argos
//
//  Popover del monitor de recursos del servidor activo: CPU, memoria, swap, disco,
//  carga, uptime y los procesos que más CPU consumen. Refresca cada pocos segundos
//  SOLO mientras está a la vista (la `.task` se cancela al cerrar el popover).
//

import SwiftUI

struct ServerResourcesView: View {
    let serverName: String
    let service: any SSHServicing

    @State private var sample: ServerResourceSample?
    /// Uso de CPU calculado entre las dos últimas muestras (`nil` hasta la segunda).
    @State private var cpuUsage: Double?
    @State private var errorMessage: String?

    private static let refreshInterval: Duration = .seconds(3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let sample {
                metrics(for: sample)
                Divider()
                processList(sample.topProcesses)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView("Leyendo recursos…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(16)
        .frame(width: 380)
        .task { await poll() }
    }

    private var header: some View {
        HStack {
            Label(serverName, systemImage: "server.rack")
                .font(.headline)
            Spacer()
            if let sample {
                Text("Encendido \(ResourceFormat.uptime(sample.uptimeSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Métricas

    private func metrics(for sample: ServerResourceSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricRow(
                title: "CPU",
                fraction: cpuUsage,
                detail: "\(sample.cores) núcleos · carga \(loadText(sample))"
            )
            MetricRow(
                title: "Memoria",
                fraction: sample.memory.fraction,
                detail: usageText(sample.memory)
            )
            if sample.swap.totalKB > 0 {
                MetricRow(title: "Swap", fraction: sample.swap.fraction, detail: usageText(sample.swap))
            }
            MetricRow(title: "Disco /", fraction: sample.disk.fraction, detail: usageText(sample.disk))
        }
    }

    private func loadText(_ sample: ServerResourceSample) -> String {
        [sample.load1, sample.load5, sample.load15]
            .map { $0.formatted(.number.precision(.fractionLength(2))) }
            .joined(separator: " / ")
    }

    private func usageText(_ usage: ResourceUsage) -> String {
        "\(ResourceFormat.kilobytes(usage.usedKB)) de \(ResourceFormat.kilobytes(usage.totalKB))"
    }

    // MARK: - Procesos

    private func processList(_ processes: [ResourceProcess]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Procesos con más CPU")
                .font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("PID")
                    Text("Proceso")
                    Text("%CPU").gridColumnAlignment(.trailing)
                    Text("%MEM").gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(processes) { process in
                    GridRow {
                        Text("\(process.pid)").foregroundStyle(.secondary)
                        Text(process.command).lineLimit(1).truncationMode(.tail)
                        Text(process.cpuPercent.formatted(.number.precision(.fractionLength(1))))
                        Text(process.memPercent.formatted(.number.precision(.fractionLength(1))))
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("%CPU es el promedio desde que arrancó cada proceso (puede superar 100 con varios núcleos).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sondeo

    private func poll() async {
        while !Task.isCancelled {
            do {
                let fresh = try await service.resourceSample()
                if let previous = sample {
                    cpuUsage = fresh.cpu.usage(since: previous.cpu) ?? cpuUsage
                }
                sample = fresh
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                Log.ssh.error("Monitor de recursos: \(error.userMessage, privacy: .public)")
                errorMessage = error.userMessage
            }
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
        }
    }
}

/// Fila de métrica: título, barra de uso coloreada por nivel y detalle.
private struct MetricRow: View {
    let title: String
    /// `nil` mientras no hay dato (p. ej. CPU antes de la segunda muestra).
    let fraction: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(fraction.map(ResourceFormat.percent) ?? "…")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(fraction.map(Self.color(for:)) ?? .secondary)
            }
            ProgressView(value: fraction ?? 0)
                .tint(fraction.map(Self.color(for:)) ?? .secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Verde < 70 %, naranja < 90 %, rojo a partir de ahí.
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
