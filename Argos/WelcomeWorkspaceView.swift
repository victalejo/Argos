//
//  WelcomeWorkspaceView.swift
//  Argos
//
//  Pantallas de bienvenida: el detalle sin nada seleccionado y la columna central
//  sin servidores.
//

import SwiftUI

/// Detalle sin proyecto seleccionado.
struct WelcomeWorkspaceView: View {
    let canSearch: Bool
    let onSearch: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                WorkspaceIcon(symbol: "square.stack.3d.up.fill", size: 80)
                VStack(spacing: 10) {
                    Text("Todo listo para trabajar")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Selecciona un proyecto y continúa donde lo dejaste.")
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 0) {
                    feature("Tu terminal, siempre a mano", detail: "Abre sesiones y cambia entre ventanas.", icon: "terminal")
                    Divider().padding(.leading, 62)
                    feature("Explora tus archivos", detail: "Consulta código, imágenes y documentos.", icon: "folder")
                    Divider().padding(.leading, 62)
                    feature("Dale una tarea a tu agente", detail: "Trabaja con Claude Code en cada proyecto.", icon: "sparkles")
                }
                .background(ArgosTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(ArgosTheme.border) }
                Button(action: onSearch) {
                    HStack(spacing: 10) {
                        Label("Buscar una sesión", systemImage: "magnifyingglass")
                        KeyboardHint(keys: "⌘ K")
                    }
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(!canSearch)
            }
            .frame(maxWidth: 450)
            .padding(.horizontal, 36).padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceBackdrop())
    }

    private func feature(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}

/// Columna central sin servidores.
struct FirstServerView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            WorkspaceIcon(symbol: "server.rack", size: 64)
            VStack(spacing: 7) {
                Text("Conecta tu primer servidor")
                    .font(.title3.weight(.semibold))
                Text("Reúne tus proyectos y sesiones SSH en un solo lugar.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Añadir servidor", action: onAdd)
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceBackdrop())
    }
}
