//
//  RemoteFileSharing.swift
//  ArgosiOS
//
//  Archivos del proyecto en iPhone/iPad, además de navegar por carpetas:
//  - Descargar ENTERO y compartir/guardar cualquier archivo (antes solo el que ya se
//    había previsualizado completo): hoja de iOS con la copia temporal, que se borra al
//    cerrarla.
//  - Buscar por nombre en todo el proyecto (como ⌘P en el Mac, sobre el mismo índice y
//    la misma búsqueda difusa de `FileBrowserModel`).
//

import SwiftUI
import UIKit

// MARK: - Descargar y compartir

/// Copia temporal descargada, lista para la hoja de compartir.
struct DownloadedFile: Identifiable {
    let url: URL
    var id: URL { url }

    /// Borra la carpeta temporal que la contiene.
    func discard() {
        do {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } catch {
            Log.store.notice("No se pudo borrar la copia temporal compartida: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum RemoteFileDownload {
    /// Descarga `entry` completo a una carpeta temporal propia, con su nombre original
    /// LIMPIO: el nombre lo manda el servidor y no debe poder sacar la escritura de la
    /// carpeta (`SafeLocalFile`).
    static func download(_ entry: RemoteFileEntry, root: String, service: any SSHServicing) async throws -> DownloadedFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let url = try SafeLocalFile.url(for: entry.name, in: folder)
            try await service.downloadRemoteFile(entry.path, root: root, to: url)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return DownloadedFile(url: url)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

/// Descarga + hoja de compartir + errores, para cualquier vista con archivos.
struct RemoteFileSharingModifier: ViewModifier {
    @Binding var request: RemoteFileEntry?
    let service: any SSHServicing
    let root: String

    @State private var downloading: String?
    @State private var file: DownloadedFile?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, entry in
                guard let entry else { return }
                request = nil
                start(entry)
            }
            .safeAreaInset(edge: .bottom) {
                if let downloading {
                    Label("Descargando «\(downloading)»…", systemImage: "arrow.down.circle")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .sheet(item: $file) { file in
                ActivityView(items: [file.url])
                    .onDisappear { file.discard() }
            }
            .alert("No se pudo descargar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func start(_ entry: RemoteFileEntry) {
        guard downloading == nil else { return }
        downloading = entry.name
        Task {
            defer { downloading = nil }
            do {
                file = try await RemoteFileDownload.download(entry, root: root, service: service)
            } catch {
                Log.store.error("Descargar \(entry.name, privacy: .private): \(error.userMessage, privacy: .public)")
                errorMessage = error.userMessage
            }
        }
    }
}

extension View {
    /// Pon un archivo en `request` para descargarlo entero y compartirlo.
    func remoteFileSharing(_ request: Binding<RemoteFileEntry?>, service: any SSHServicing, root: String) -> some View {
        modifier(RemoteFileSharingModifier(request: request, service: service, root: root))
    }
}

/// Hoja de compartir de iOS (guardar en Archivos, AirDrop, abrir con otra app…).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Buscar por nombre

struct FileSearchSheet: View {
    let service: any SSHServicing
    let root: String

    @Environment(\.dismiss) private var dismiss
    @State private var index: [String]?
    @State private var query = ""
    @State private var errorMessage: String?
    @State private var sharing: RemoteFileEntry?

    private var results: [String] {
        FileBrowserModel.matches(query, in: index ?? [])
    }

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    ContentUnavailableView {
                        Label("No se pudo buscar", systemImage: "magnifyingglass")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Reintentar") { Task { await load() } }
                    }
                } else if index == nil {
                    ProgressView("Indexando el proyecto…")
                } else {
                    List(results, id: \.self) { relative in
                        let entry = entry(for: relative)
                        NavigationLink {
                            FilePreviewScreen(service: service, root: root, entry: entry)
                        } label: {
                            searchRow(relative, entry: entry)
                        }
                        .contextMenu {
                            Button("Descargar y compartir…", systemImage: "square.and.arrow.up") { sharing = entry }
                        }
                    }
                    .overlay {
                        if results.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nombre del archivo")
            .navigationTitle("Buscar archivos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .remoteFileSharing($sharing, service: service, root: root)
        }
        .task { if index == nil { await load() } }
    }

    private func entry(for relative: String) -> RemoteFileEntry {
        RemoteFileEntry(name: (relative as NSString).lastPathComponent, path: RemotePath.join(root, relative), kind: .file)
    }

    private func searchRow(_ relative: String, entry: RemoteFileEntry) -> some View {
        let icon = FileIcon.icon(for: entry)
        let folder = (relative as NSString).deletingLastPathComponent
        return HStack(spacing: 12) {
            Image(systemName: icon.symbol).foregroundStyle(icon.tint.color).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }

    private func load() async {
        do {
            index = try await service.indexProjectFiles(root: root)
            errorMessage = nil
        } catch {
            Log.store.notice("Índice de archivos: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
    }
}
