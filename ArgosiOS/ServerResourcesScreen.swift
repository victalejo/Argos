//
//  ServerResourcesScreen.swift
//  ArgosiOS
//
//  Monitor de recursos del servidor en iPhone/iPad (en el Mac es un popover,
//  `ServerResourcesView`): CPU, memoria, swap, disco, carga, uptime y los procesos que
//  más CPU consumen. La lógica (muestra y parseo) es la compartida de
//  `ArgosCore/Monitor/`. Solo sondea mientras está a la vista y con la app activa.
//

import SwiftUI

struct ServerResourcesScreen: View {
    let serverName: String
    let service: any SSHServicing

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sample: ServerResourceSample?
    /// Uso de CPU entre las dos últimas muestras (`nil` hasta la segunda).
    @State private var cpuUsage: Double?
    @State private var errorMessage: String?

    private static let refreshInterval: Duration = .seconds(3)

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Recursos de \(serverName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Hecho") { dismiss() }
                    }
                }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await poll()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let sample {
            List {
                if let errorMessage {
                    Label("No se pudo actualizar; se muestran los últimos datos. \(errorMessage)",
                          systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Section {
                    ResourceMetricRow(title: "CPU", fraction: cpuUsage,
                                      detail: "\(sample.cores) núcleos · carga \(loadText(sample))")
                    ResourceMetricRow(title: "Memoria", fraction: sample.memory.fraction, detail: usageText(sample.memory))
                    if sample.swap.totalKB > 0 {
                        ResourceMetricRow(title: "Swap", fraction: sample.swap.fraction, detail: usageText(sample.swap))
                    }
                    ResourceMetricRow(title: "Disco /", fraction: sample.disk.fraction, detail: usageText(sample.disk))
                } header: {
                    Text("Encendido \(ResourceFormat.uptime(sample.uptimeSeconds)) · cada 3 s")
                }
                Section {
                    ForEach(sample.topProcesses) { process in
                        processRow(process)
                    }
                } header: {
                    Text("Procesos con más CPU")
                } footer: {
                    Text("%CPU es el promedio desde que arrancó cada proceso (puede superar 100 con varios núcleos).")
                }
            }
        } else if let errorMessage {
            ContentUnavailableView {
                Label("No se pudieron leer los recursos", systemImage: "gauge.with.dots.needle.0percent")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Reintentar") {
                    Task {
                        await service.resetConnectionHealth()
                        await readOnce()
                    }
                }
            }
        } else {
            ProgressView("Leyendo recursos…")
        }
    }

    private func processRow(_ process: ResourceProcess) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.command).lineLimit(1).truncationMode(.tail)
                Text("PID \(process.pid)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(process.cpuPercent.formatted(.number.precision(.fractionLength(1)))) % CPU")
                Text("\(process.memPercent.formatted(.number.precision(.fractionLength(1)))) % mem")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func loadText(_ sample: ServerResourceSample) -> String {
        [sample.load1, sample.load5, sample.load15]
            .map { $0.formatted(.number.precision(.fractionLength(2))) }
            .joined(separator: " / ")
    }

    private func usageText(_ usage: ResourceUsage) -> String {
        "\(ResourceFormat.kilobytes(usage.usedKB)) de \(ResourceFormat.kilobytes(usage.totalKB))"
    }

    // MARK: - Sondeo

    private func poll() async {
        while !Task.isCancelled {
            // Refresco periódico = sondeo de fondo: tras un fallo espera en vez de insistir.
            await ConnectionPriority.background { await readOnce() }
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
        }
    }

    private func readOnce() async {
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
            Log.ssh.error("Monitor de recursos: \(error.userMessage, privacy: .private)")
            errorMessage = error.userMessage
        }
    }
}

/// Métrica con barra coloreada por nivel: verde < 70 %, naranja < 90 %, rojo después.
private struct ResourceMetricRow: View {
    let title: String
    let fraction: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                Text(fraction.map(ResourceFormat.percent) ?? "…")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(fraction.map(Self.color(for:)) ?? .secondary)
            }
            ProgressView(value: fraction ?? 0)
                .tint(fraction.map(Self.color(for:)) ?? .secondary)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
