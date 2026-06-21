//
//  RemoteDirectoryPicker.swift
//  Argos
//
//  Selector visual de carpetas del servidor (vía SSH): navega por el árbol y elige una
//  sin teclear la ruta de memoria. Empieza en la última carpeta usada (o `~`).
//

import SwiftUI

struct RemoteDirectoryPicker: View {
    let service: any SSHServicing
    let startPath: String
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var listing: RemoteDirectoryListing?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .task { await load(startPath) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Elegir carpeta del servidor").font(.headline)
            Text(listing?.path ?? "…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView("No se pudo abrir la carpeta", systemImage: "folder.badge.questionmark",
                                   description: Text(error))
        } else if let listing {
            List {
                if listing.path != "/" {
                    Button {
                        Task { await load(parent(of: listing.path)) }
                    } label: {
                        Label("..", systemImage: "arrow.up.left")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(listing.subdirectories, id: \.self) { dir in
                    Button {
                        Task { await load(join(listing.path, dir)) }
                    } label: {
                        Label(dir, systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
                if listing.subdirectories.isEmpty {
                    Text("(sin subcarpetas)").foregroundStyle(.secondary).font(.caption)
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancelar", role: .cancel) { onCancel() }
            Spacer()
            Button("Usar esta carpeta") {
                if let path = listing?.path { onPick(path) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(listing == nil)
        }
        .padding(12)
    }

    private func load(_ path: String) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            listing = try await service.listRemoteDirectories(at: path)
        } catch {
            self.error = error.userMessage
        }
    }

    /// Carpeta padre de una ruta absoluta.
    private func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    /// Une una ruta base con un nombre de subcarpeta.
    private func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
