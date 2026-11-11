//
//  RemoteFolderPicker.swift
//  ArgosiOS
//
//  Selector de carpetas del servidor para el formulario de proyecto (el del Mac es
//  `RemoteDirectoryPicker`): navega por el árbol, crea carpetas y elige la actual.
//

import SwiftUI

struct RemoteFolderPicker: View {
    let service: any SSHServicing
    let startPath: String
    let onPick: (String) -> Void

    @State private var listing: RemoteDirectoryListing?
    @State private var loading = false
    @State private var error: String?
    @State private var creatingFolder = false
    @State private var newFolderName = ""

    var body: some View {
        content
            .navigationTitle(listing.map { ($0.path as NSString).lastPathComponent.isEmpty ? "/" : ($0.path as NSString).lastPathComponent } ?? "Carpeta")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Nueva carpeta", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        creatingFolder = true
                    }
                    .disabled(listing == nil)
                }
            }
            .alert("Nueva carpeta", isPresented: $creatingFolder) {
                TextField("Nombre", text: $newFolderName)
                    .plainCodeInput()
                Button("Cancelar", role: .cancel) {}
                Button("Crear") { Task { await createFolder() } }
            } message: {
                Text("Se crea dentro de \(listing?.path ?? "la carpeta actual").")
            }
            .task { await load(startPath) }
    }

    @ViewBuilder
    private var content: some View {
        if loading && listing == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, listing == nil {
            ContentUnavailableView("No se pudo abrir la carpeta", systemImage: "folder.badge.questionmark",
                                   description: Text(error))
        } else if let listing {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
                Section {
                    if listing.path != "/" {
                        Button { Task { await load(Self.parent(of: listing.path)) } } label: {
                            Label("Carpeta superior", systemImage: "arrow.up.left")
                        }
                    }
                    ForEach(listing.subdirectories, id: \.self) { dir in
                        Button { Task { await load(Self.join(listing.path, dir)) } } label: {
                            Label(dir, systemImage: "folder")
                        }
                    }
                } header: {
                    Text(listing.path).font(.caption.monospaced()).textCase(nil)
                } footer: {
                    if listing.subdirectories.isEmpty { Text("Sin subcarpetas.") }
                }
            }
            .foregroundStyle(.primary)
            .disabled(loading)
        }
    }

    private var footer: some View {
        Button {
            if let path = listing?.path { onPick(path) }
        } label: {
            Text("Usar esta carpeta").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(listing == nil || loading)
        .padding()
        .background(.bar)
    }

    /// Crea la carpeta en la actual y entra en ella (lista para «Usar esta carpeta»).
    private func createFolder() async {
        guard let base = listing?.path else { return }
        switch FolderNameValidator.validate(newFolderName) {
        case .failure(let failure):
            error = failure.localizedDescription
        case .success(let name):
            do {
                if listing?.subdirectories.contains(name) != true {
                    try await service.makeRemoteDirectories(root: base, relativeDirectories: [name])
                }
                await load(Self.join(base, name))
            } catch {
                self.error = error.userMessage
            }
        }
    }

    private func load(_ path: String) async {
        loading = true
        defer { loading = false }
        do {
            listing = try await service.listRemoteDirectories(at: path)
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }

    /// Carpeta padre de una ruta absoluta.
    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// Une una ruta base con un nombre de subcarpeta.
    static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
