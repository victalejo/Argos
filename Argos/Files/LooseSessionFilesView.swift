//
//  LooseSessionFilesView.swift
//  Argos
//
//  Pestaña "Archivos" de una sesión SIN proyecto: usa la carpeta en la que está su
//  primer panel como raíz del explorador.
//

import SwiftUI

struct LooseSessionFilesView: View {
    let sessionName: String
    let service: any SSHServicing

    @State private var root: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let root {
                FilesPanelView(root: root, service: service)
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
