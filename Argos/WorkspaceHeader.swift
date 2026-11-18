//
//  WorkspaceHeader.swift
//  Argos
//
//  Cabecera de la columna central: título, recuentos, búsqueda (⌘F) y filtros por
//  estado; y el pie con la pista de uso.
//

import SwiftUI

struct WorkspaceHeader: View {
    @Binding var searchText: String
    @Binding var statusFilter: ProjectStatusFilter
    var searchFocused: FocusState<Bool>.Binding
    let projectCount: Int
    let runningCount: Int
    /// Proyectos (y sesiones sueltas) por filtro, en los servidores cargados.
    let statusCounts: [ProjectStatusFilter: Int]
    let canCreateProject: Bool
    let onNewProject: () -> Void
    /// Intro en la búsqueda: abre el primer resultado visible (si lo hay).
    let onSubmitSearch: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleRow
            HStack(spacing: 14) {
                Label("\(projectCount) proyectos", systemImage: "folder")
                Label("\(runningCount) en marcha", systemImage: "bolt.fill")
                    .foregroundStyle(.teal)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            searchField
            statusFilterBar
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var titleRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ESPACIO DE TRABAJO")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Text("Proyectos")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
            }
            Spacer()
            Button(action: onNewProject) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 9))
            .disabled(!canCreateProject)
            .help("Nuevo proyecto (⌘N)")
            .accessibilityLabel("Nuevo proyecto")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Buscar proyectos o sesiones…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(searchFocused)
                .onKeyPress(.escape) {
                    if searchText.isEmpty { searchFocused.wrappedValue = false } else { searchText = "" }
                    return .handled
                }
                .onKeyPress(.return) {
                    onSubmitSearch()
                    // Intro es de la búsqueda aunque no haya resultados: que no lo reciba
                    // el botón por defecto «Abrir» de un proyecto.
                    return .handled
                }
                .accessibilityLabel("Buscar proyectos o sesiones")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Borrar búsqueda")
                .accessibilityLabel("Borrar búsqueda")
            } else {
                Text("⌘F")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(searchFocused.wrappedValue ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.07), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: searchFocused.wrappedValue)
    }

    /// Botones para filtrar por estado (con su número). Pulsar el activo vuelve a «Todos».
    private var statusFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ProjectStatusFilter.allCases) { option in
                    filterButton(option, count: statusCounts[option] ?? 0)
                }
            }
        }
    }

    private func filterButton(_ option: ProjectStatusFilter, count: Int) -> some View {
        let isOn = statusFilter == option
        return Button {
            statusFilter = (isOn && option != .all) ? .all : option
        } label: {
            HStack(spacing: 4) {
                Image(systemName: option.systemImage)
                Text(option.title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Color.white.opacity(0.8) : Color.secondary)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(option.help)
        .accessibilityLabel("\(option.title), \(count)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Pie de la columna central.
struct WorkspaceFooter: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow")
            Text("Selecciona para abrir · Clic derecho para más")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}
