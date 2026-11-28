//
//  ClaudeTaskModelPicker.swift
//  ArgosUI
//
//  Selector de modelo y esfuerzo de un encargo o de una tarea programada (Mac e
//  iPhone/iPad). «Por defecto» deja el que tenga Claude Code.
//

import SwiftUI

struct ClaudeTaskModelPicker: View {
    @Binding var choice: ClaudeTaskModelChoice
    /// El encargo va a la terminal: avisa de que se cambia el modelo de esa ventana.
    var inTerminal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelPicker
            effortPicker
            if inTerminal && !choice.isDefault {
                Text("En la terminal, Argos escribe /model y /effort antes del encargo y, al terminar, vuelve a poner los que Claude Code tenía guardados. Mientras dura, esa ventana (y las sesiones nuevas de Claude Code) usan los del encargo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelPicker: some View {
        let binding: Binding<ClaudeTaskModel?> = Binding(
            get: { choice.model },
            set: { (value: ClaudeTaskModel?) in choice.model = value }
        )
        return Picker("Modelo", selection: binding) {
            Text("Por defecto").tag(ClaudeTaskModel?.none)
            ForEach(ClaudeTaskModel.allCases, id: \.self) { (model: ClaudeTaskModel) in
                Text(verbatim: model.displayName).tag(ClaudeTaskModel?.some(model))
            }
        }
    }

    private var effortPicker: some View {
        let binding: Binding<ClaudeTaskEffort?> = Binding(
            get: { choice.effort },
            set: { (value: ClaudeTaskEffort?) in choice.effort = value }
        )
        return Picker("Esfuerzo", selection: binding) {
            Text("Por defecto").tag(ClaudeTaskEffort?.none)
            ForEach(ClaudeTaskEffort.allCases, id: \.self) { (effort: ClaudeTaskEffort) in
                Text(verbatim: effort.label).tag(ClaudeTaskEffort?.some(effort))
            }
        }
    }
}
