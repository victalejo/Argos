//
//  ClaudeLimitsViews.swift
//  ArgosUI
//
//  Límites de uso de Claude (Mac e iPhone/iPad): medidores por ventana, aviso al acercarse
//  al límite y la pantalla para activar o quitar la statusline de Argos que los lee.
//

import SwiftUI

/// Una barra por ventana (5 h, semana…) con su porcentaje y cuándo se reinicia.
struct ClaudeLimitsMeters: View {
    let status: ClaudeLimitsStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(status.reading.windows, id: \.kind) { window in
                    ClaudeLimitMeterRow(window: window, now: context.date)
                }
                updatedLine
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var updatedLine: some View {
        HStack(spacing: 4) {
            Text("Actualizado")
            Text(status.reading.capturedAt, style: .relative)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

private struct ClaudeLimitMeterRow: View {
    let window: ClaudeLimitWindow
    let now: Date

    private var percent: Double { window.effectivePercent(now: now) }

    private var tint: Color {
        if percent >= Double(ClaudeLimitsStatus.criticalFrom) { return .red }
        if percent >= Double(ClaudeLimitsStatus.highFrom) { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Text("\(Int(percent.rounded())) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: percent, total: 100)
                .progressViewStyle(.linear)
                .tint(tint)
            if let reset = window.resetsAt, reset > now {
                Text("Se reinicia \(ClaudeLimitsStatus.resetText(reset, now: now))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Línea compacta para la lista del servidor: «Claude · 5 h 42 % · semana 8 %».
struct ClaudeLimitsCompactRow: View {
    let status: ClaudeLimitsStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let now = Date()
        let parts = status.reading.windows.map { window in
            "\(window.label) \(Int(window.effectivePercent(now: now).rounded())) %"
        }
        return parts.joined(separator: " · ")
    }
}

/// Aviso «te acercas al límite de Claude» (solo con nivel alto o crítico).
struct ClaudeLimitsBanner: View {
    let status: ClaudeLimitsStatus

    private var tint: Color { status.level == .critical ? .red : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.100percent")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                Text(status.message())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Explicación, estado y botones para activar o quitar la lectura de límites.
struct ClaudeLimitsSetupView: View {
    let model: ClaudeLimitsSetupModel
    let status: ClaudeLimitsStatus?
    let serverName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Argos puede enseñarte cuánto llevas usado de tus límites de Claude en «\(serverName)»: la ventana de 5 horas y la semanal, con la hora a la que se reinician, y avisarte al llegar al \(ClaudeLimitsStatus.highFrom) %."))
                .fixedSize(horizontal: false, vertical: true)
            Text("Claude Code solo entrega esos datos a su barra de estado, así que Argos pone la suya en ~/.claude/settings.json (con copia en settings.json.argos-backup): guarda los límites en ~/.config/argos y después ejecuta tu barra de estado anterior, que se sigue viendo igual. Al quitarla vuelve la tuya.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            stateSection
            if let status {
                ClaudeLimitsMeters(status: status)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .inactive:
            Button("Activar límites de Claude") { Task { await model.activate() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
        case .active:
            HStack(spacing: 12) {
                Label("Activo", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Quitar", role: .destructive) { Task { await model.deactivate() } }
                    .disabled(model.isWorking)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reintentar") { Task { await model.refresh() } }
            }
        }
    }
}
