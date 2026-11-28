//
//  ServerMetricsHistoryView.swift
//  ArgosUI
//
//  Historial de recursos del servidor (Mac e iPhone/iPad): memoria y swap, CPU, carga y
//  memoria de Claude en 6 h / 24 h / 7 días, con las marcas de OOM del kernel. Si el
//  muestreo no está puesto, explica qué hace y deja ponerlo («Guardar historial»).
//

import Charts
import SwiftUI

struct ServerMetricsHistoryView: View {
    @Bindable var model: ServerMetricsModel
    @State private var isConfirmingUninstall = false

    /// Las muestras llegan cada minuto: refrescar más a menudo no aporta nada.
    private static let refreshInterval: Duration = .seconds(60)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .task(id: model.reloadToken) { await refreshLoop() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Leyendo el historial…").frame(maxWidth: .infinity, minHeight: 100)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Reintentar") { model.retry() }
            }
        case .loaded:
            if model.history.isInstalled {
                installedContent
            } else {
                MetricsInstallPrompt(model: model)
            }
        }
    }

    @ViewBuilder
    private var installedContent: some View {
        Picker("Periodo", selection: $model.range) {
            ForEach(ServerMetricsRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if model.history.isStalled {
            Label("No hay temporizador en el servidor: el historial no avanza. Vuelve a pulsar «Guardar historial».",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.history.lacksProc {
            Text("Este servidor no es Linux (no tiene /proc): no hay muestras que guardar.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.history.points.isEmpty {
            Text("Aún no hay muestras: se toma una cada minuto, aunque no tengas la app abierta.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MetricsCharts(points: model.chartPoints, marks: model.visibleOOMMarks, range: model.range)
            MemoryHogsList(processes: model.history.topProcesses)
        }
        footer
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.actionError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Se guarda en el servidor: 1 muestra por minuto durante 24 h y cada 10 min hasta 7 días.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dejar de guardar", role: .destructive) { isConfirmingUninstall = true }
                    .controlSize(.small)
                    .disabled(model.isWorking)
            }
        }
        .confirmationDialog("¿Dejar de guardar el historial?", isPresented: $isConfirmingUninstall) {
            Button("Dejar de guardar y borrar el historial", role: .destructive) {
                Task { await model.uninstall() }
            }
        } message: {
            Text("Se quita el muestreo del servidor y se borra lo guardado. El temporizador del servidor se queda: lo usan también los encargos y los presupuestos.")
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await model.load()
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
        }
    }
}

/// Explicación y botón para poner el muestreo.
private struct MetricsInstallPrompt: View {
    let model: ServerMetricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Guarda en el servidor una muestra por minuto de memoria, swap, CPU, carga y procesos de Claude, aunque no tengas la app abierta. Así verás la tendencia antes de que el sistema se quede sin memoria y qué la llenó.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if model.history.lacksProc {
                Text("Este servidor no es Linux (no tiene /proc): el historial no tendrá datos.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.install() }
                } label: {
                    Label("Guardar historial", systemImage: "chart.xyaxis.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            if let error = model.actionError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("Usa el mismo temporizador que las tareas programadas (systemd, launchd o cron) y ocupa como mucho unos cientos de KB.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Los 5 procesos con más memoria en la última muestra.
private struct MemoryHogsList: View {
    let processes: [ServerMemoryHog]

    var body: some View {
        if !processes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Más memoria ahora").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(processes) { process in
                    row(process)
                }
            }
        }
    }

    private func row(_ process: ServerMemoryHog) -> some View {
        HStack {
            Text(process.name).lineLimit(1)
            Text("PID \(String(process.pid))").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(ResourceFormat.kilobytes(process.rssKB)).monospacedDigit()
        }
        .font(.caption)
    }
}
