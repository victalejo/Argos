//
//  LooseSessionFilesView.swift
//  Argos
//
//  Pestañas "Archivos" y "Cambios" de una sesión SIN proyecto: usan la carpeta en la
//  que está su primer panel como raíz.
//

import SwiftUI

struct LooseSessionFilesView: View {
    let sessionName: String
    let service: any SSHServicing

    var body: some View {
        LooseSessionRootView(sessionName: sessionName, service: service) { root in
            FilesPanelView(root: root, service: service)
        }
    }
}

/// Resuelve la carpeta de una sesión suelta y muestra `content` con ella.
struct LooseSessionRootView<Content: View>: View {
    let sessionName: String
    let service: any SSHServicing
    @ViewBuilder let content: (String) -> Content

    @State private var root: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let root {
                content(root)
            } else if failed {
                ContentUnavailableView(
                    "Carpeta desconocida",
                    systemImage: "questionmark.folder",
                    description: Text("No se pudo saber en qué carpeta está esta sesión. "
                                      + "Conviértela en proyecto para fijar su carpeta.")
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let path = try? await service.sessionFirstPanePaths()[sessionName]
            if let path, path.hasPrefix("/") { root = path } else { failed = true }
        }
    }
}
