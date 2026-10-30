//
//  ImportProjectsSheet.swift
//  Argos
//
//  Convierte las sesiones sueltas de un servidor en proyectos de una vez, usando la
//  carpeta de su primer panel. El usuario revisa y desmarca antes de importar.
//

import SwiftUI

struct ImportProjectsSheet: View {
    let server: Server
    let vm: SessionsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [Project] = []
    @State private var selected: Set<UUID> = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Importar sesiones como proyectos")
                    .font(.title2.weight(.semibold))
                Text("Cada sesión de \(server.name) se guarda como proyecto anclado a la carpeta en la que está. "
                     + "Las sesiones siguen corriendo; solo dejan de ser \"sueltas\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
                .frame(minHeight: 220, maxHeight: 420)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isImporting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Importar \(selected.count)") { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || isImporting)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await loadCandidates() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Leyendo carpetas de las sesiones…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            ContentUnavailableView(
                "Nada que importar",
                systemImage: "checkmark.circle",
                description: Text("No hay sesiones sueltas con una carpeta conocida.")
            )
        } else {
            List(candidates) { project in
                Toggle(isOn: binding(for: project.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.sessionName).font(.body.weight(.medium))
                        Text(project.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func loadCandidates() async {
        do {
            candidates = try await vm.importCandidates()
            selected = Set(candidates.map(\.id))
        } catch {
            errorMessage = error.userMessage
        }
        isLoading = false
    }

    private func importSelected() {
        isImporting = true
        errorMessage = nil
        let chosen = candidates.filter { selected.contains($0.id) }
        Task {
            do {
                try await vm.importProjects(chosen)
                dismiss()
            } catch {
                errorMessage = error.userMessage
                isImporting = false
            }
        }
    }
}
