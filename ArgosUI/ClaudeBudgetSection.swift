//
//  ClaudeBudgetSection.swift
//  ArgosUI
//
//  Apartado «Presupuesto» de los encargos de un proyecto (Mac e iPhone/iPad): topes de la
//  ventana de 5 h y diario, y lo gastado frente a cada uno.
//

import SwiftUI

struct ClaudeBudgetSection: View {
    @Bindable var model: ClaudeBudgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Presupuesto").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.reading == nil {
                loading
            } else if !model.canEdit {
                Text("Este presupuesto lo guardó una versión más nueva de Argos: actualiza la app para cambiarlo.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                warnings
                ClaudeBudgetWindowRow(model: model)
                ClaudeBudgetDailyRow(model: model)
                footer
            }
        }
    }

    @ViewBuilder
    private var loading: some View {
        if let error = model.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if model.dispatcherOutdated {
            Label("Otro dispositivo con una versión anterior de Argos instaló un despachador sin presupuesto: hasta que actualices Argos allí, el presupuesto no frena.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if model.lacksTimer {
            Label("El servidor no tiene launchd, systemd ni cron: un encargo frenado no empezará solo al liberarse el presupuesto.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Frena la cola y las tareas programadas de este proyecto antes de empezar un encargo; lo que ya corre no se corta y lo que lances a mano en el terminal no se frena. El gasto es una estimación con precios de la API.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Guardar presupuesto") { Task { await model.save() } }
                    .disabled(!model.canSave)
            }
        }
    }
}

/// Tope de la ventana de 5 h.
private struct ClaudeBudgetWindowRow: View {
    @Bindable var model: ClaudeBudgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Tope en la ventana de 5 h", isOn: $model.windowEnabled)
            if model.windowEnabled {
                Stepper(value: $model.windowPercent, in: ClaudeProjectBudget.windowRange, step: 5) {
                    Text("Como mucho el \(model.windowPercent) % de la ventana")
                }
                status
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.evaluation()?.window {
        case .unavailable?:
            Label("Activa los límites de Claude (Ajustes del servidor) para usar este tope: sin ellos no frena.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .meter(let meter)?:
            ClaudeBudgetMeterView(meter: meter, text: Self.text(meter))
        case .notSet?, nil:
            EmptyView()
        }
    }

    private static func text(_ meter: ClaudeBudgetMeter) -> String {
        let used = String(Int(meter.used.rounded()))
        let cap = String(Int(meter.cap.rounded()))
        guard let release = meter.releasesAt else { return String(localized: "Lleva \(used) % de \(cap) % de la ventana actual.") }
        let when = ClaudeLimitsStatus.resetText(release, now: Date())
        return String(localized: "Lleva \(used) % de \(cap) % de la ventana actual; se reinicia \(when).")
    }
}

/// Tope diario en coste equivalente.
private struct ClaudeBudgetDailyRow: View {
    @Bindable var model: ClaudeBudgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Máximo al día", isOn: $model.dailyEnabled)
            if model.dailyEnabled {
                HStack {
                    Text("USD al día")
                    Spacer()
                    TextField("USD", value: $model.dailyUSD, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                        .accessibilityLabel(Text("Máximo al día en dólares"))
                }
                if let meter = model.evaluation()?.daily {
                    ClaudeBudgetMeterView(meter: meter, text: Self.text(meter))
                }
            }
        }
    }

    private static func text(_ meter: ClaudeBudgetMeter) -> String {
        let used = ClaudeBudgetFormat.usd(meter.used)
        let cap = ClaudeBudgetFormat.usd(meter.cap)
        return String(localized: "Hoy lleva \(used) de \(cap) (día del servidor).")
    }
}

/// Barra de lo gastado frente al tope (con texto: nada depende solo del color).
private struct ClaudeBudgetMeterView: View {
    let meter: ClaudeBudgetMeter
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: meter.fraction)
                .tint(meter.isExceeded ? Color.red : meter.fraction >= 0.8 ? Color.orange : Color.accentColor)
            Text(meter.isExceeded ? String(localized: "Tope alcanzado. \(text)") : text)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
