//
//  FileDownloads.swift
//  Argos
//
//  «Descargar al Mac…» del explorador: el usuario elige dónde guardar (panel de
//  guardado, que concede el permiso del sandbox) y el archivo entero se copia por SFTP.
//

import AppKit
import UniformTypeIdentifiers

/// Estado de la última descarga (banner en el visor).
enum FileDownloadStatus: Equatable {
    case downloading(name: String)
    case saved(URL)
    case failed(name: String, message: String)
}

@MainActor
enum FileDownloads {
    /// Pide destino (por defecto Descargas, con el mismo nombre) y descarga.
    static func start(_ entry: RemoteFileEntry, model: FileBrowserModel) {
        let panel = NSSavePanel()
        panel.title = "Descargar «\(entry.name)» al Mac"
        panel.prompt = "Descargar"
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let type = UTType(filenameExtension: RemotePath.fileExtension(entry.name)) {
            panel.allowedContentTypes = [type]
            panel.allowsOtherFileTypes = true
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.downloadToMac(entry, to: url) }
    }
}

import SwiftUI

/// Aviso flotante del visor con el estado de la última descarga al Mac.
struct FileDownloadBanner: View {
    let model: FileBrowserModel

    var body: some View {
        if let status = model.downloadStatus {
            HStack(spacing: 10) {
                content(status)
                Spacer(minLength: 8)
                if case .downloading = status {} else {
                    Button { model.downloadStatus = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cerrar aviso")
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(16)
            .task(id: status) {
                // El aviso de "guardado" se va solo; los errores se quedan hasta cerrarlos.
                guard case .saved = status else { return }
                try? await Task.sleep(for: .seconds(8))
                if model.downloadStatus == status { model.downloadStatus = nil }
            }
        }
    }

    @ViewBuilder
    private func content(_ status: FileDownloadStatus) -> some View {
        switch status {
        case .downloading(let name):
            ProgressView().controlSize(.small)
            Text("Descargando \(name)…").lineLimit(1).truncationMode(.middle)
        case .saved(let url):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Guardado: \(url.lastPathComponent)").lineLimit(1).truncationMode(.middle)
            Button("Abrir") { NSWorkspace.shared.open(url) }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .failed(let name, let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("No se pudo descargar \(name): \(message)")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
