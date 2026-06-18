//
//  UpdateAvailableSheet.swift
//  Argos
//
//  Hoja que se muestra cuando hay una versión más reciente en GitHub Releases.
//

import SwiftUI

struct UpdateAvailableSheet: View {
    let info: UpdateChecker.UpdateInfo
    let currentVersion: String
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Actualización disponible")
                        .font(.title2.weight(.semibold))
                    Text("Argos \(info.version) · tienes \(currentVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !info.notes.isEmpty {
                ScrollView {
                    Text(info.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 280)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Ahora no") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Ver release") { openURL(info.releaseURL) }
                Button("Descargar") {
                    openURL(info.downloadURL ?? info.releaseURL)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
