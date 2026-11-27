//
//  ClaudeSchedulesView.swift
//  ArgosUI
//
//  Tareas programadas de un proyecto (Mac e iPhone/iPad): las existentes y el formulario
//  de una nueva («cada noche a las 3:00, corre los tests y arregla lo que falle»).
//

import SwiftUI

struct ClaudeSchedulesView: View {
    @Bindable var model: ClaudeSchedulesModel
    @State private var showsForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cada ejecución trabaja en un agente aparte, en su propia rama, y hace commit al terminar. No arranca si Claude está trabajando en el proyecto, si vas cerca del límite de uso o si el servidor va justo de memoria.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.schedules) { schedule in
                ClaudeScheduleRow(schedule: schedule, model: model)
            }
            if let notice = model.notice {
                Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Nueva tarea programada", isExpanded: $showsForm) {
                ClaudeScheduleForm(model: model)
                    .padding(.top, 6)
            }
        }
        .task { await model.load() }
    }
}

private struct ClaudeScheduleRow: View {
    let schedule: ClaudeSchedule
    let model: ClaudeSchedulesModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.title).font(.callout.weight(.medium))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Toggle("Activa", isOn: Binding(
                get: { schedule.enabled },
                set: { (on: Bool) in Task { await model.setEnabled(schedule, on) } }
            ))
            .labelsHidden()
            Menu {
                Button("Ejecutar ahora") { Task { await model.runNow(schedule) } }
                Button("Borrar", role: .destructive) { Task { await model.delete(schedule) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("Más"))
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let days = ClaudeScheduleDays.text(schedule.weekdays)
        var text = String(localized: "\(days) a las \(schedule.timeText)")
        if schedule.push { text += " · " + String(localized: "push a main") }
        if let last = schedule.lastRun {
            text += " · " + String(localized: "última: \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return text
    }
}

private struct ClaudeScheduleForm: View {
    @Bindable var model: ClaudeSchedulesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Nombre (p. ej. Tests de la noche)", text: $model.title)
            TextEditor(text: $model.prompt)
                .frame(minHeight: 70, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .accessibilityLabel(Text("Encargo para Claude"))
            ClaudeWeekdayPicker(selection: $model.weekdays)
            DatePicker("Hora", selection: $model.time, displayedComponents: .hourAndMinute)
            Stepper("Tiempo máximo: \(model.maxMinutes) min", value: $model.maxMinutes, in: 10...480, step: 10)
            Toggle("Push a main al terminar", isOn: $model.push)
            if model.push {
                TextField("Comprobación antes del push (p. ej. npm test)", text: $model.checkCommand)
            }
            HStack {
                if !model.savedPrompts.isEmpty {
                    SavedPromptMenu(prompts: model.savedPrompts) { (prompt: SavedPrompt) in model.usePrompt(prompt) }
                        .fixedSize()
                }
                Spacer()
                Button("Guardar tarea") { Task { await model.add() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
            }
        }
    }
}

/// Días de la semana como botones (1 = lunes … 7 = domingo).
private struct ClaudeWeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { (day: Int) in
                let on = selection.contains(day)
                Button(ClaudeScheduleDays.letter(day)) {
                    if on { selection.remove(day) } else { selection.insert(day) }
                }
                .buttonStyle(.bordered)
                .tint(on ? .accentColor : .secondary)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Textos de los días (lunes = 1, como `date +%u`).
enum ClaudeScheduleDays {
    static func letter(_ day: Int) -> String {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols // domingo primero
        return symbols[day % 7]
    }

    static func text(_ days: Set<Int>) -> String {
        if days == Set(1...7) { return String(localized: "Todos los días") }
        if days == Set(1...5) { return String(localized: "De lunes a viernes") }
        let symbols = Calendar.current.shortStandaloneWeekdaySymbols
        return days.sorted().map { symbols[$0 % 7] }.joined(separator: ", ")
    }
}
