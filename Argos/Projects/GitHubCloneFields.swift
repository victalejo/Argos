//
//  GitHubCloneFields.swift
//  Argos
//
//  Campos «Clonar de GitHub» del formulario de nuevo proyecto: el repositorio (escrito o
//  elegido de los tuyos, que lista el `gh` del servidor), dónde clonarlo y la carpeta.
//

import SwiftUI

struct GitHubCloneFields: View {
    @Bindable var clone: GitHubCloneModel
    let serverName: String
    let onPickParent: () -> Void

    var body: some View {
        Section {
            HStack {
                TextField("Repositorio", text: $clone.repository, prompt: Text("dueño/nombre o URL"))
                    .font(.body.monospaced())
                repositoryMenu
            }
            repositoriesStatus
        } header: {
            Label("Repositorio de GitHub", systemImage: "arrow.down.circle")
        } footer: {
            Text("Se clona en el servidor con su `gh`: Argos no necesita tus credenciales de GitHub.")
                .font(.caption)
        }
        .task { await clone.loadRepositories() }

        Section {
            HStack {
                TextField("Dentro de", text: $clone.parent, prompt: Text("~/proyectos"))
                    .font(.body.monospaced())
                Button("Explorar…", action: onPickParent)
                    .help("Explorar las carpetas de \(serverName)")
            }
            TextField("Carpeta", text: $clone.folder, prompt: Text("nombre-del-repo"))
                .font(.body.monospaced())
        } header: {
            Label("Dónde clonarlo", systemImage: "folder")
        } footer: {
            if let error = clone.validationError, !clone.repository.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("Se creará \(clone.destination)").font(.caption.monospaced())
            }
        }
    }

    @ViewBuilder
    private var repositoryMenu: some View {
        if case .loaded(let repos) = clone.repositories, !repos.isEmpty {
            Menu {
                ForEach(repos) { repo in
                    Button {
                        clone.choose(repo)
                    } label: {
                        Label(repo.nameWithOwner, systemImage: repo.isPrivate ? "lock" : "book.closed")
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Elegir uno de tus repositorios")
            .accessibilityLabel("Elegir uno de tus repositorios")
        }
    }

    @ViewBuilder
    private var repositoriesStatus: some View {
        switch clone.repositories {
        case .idle, .loaded:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Cargando tus repositorios…").font(.caption).foregroundStyle(.secondary)
            }
        case .ghMissing:
            Text("Instala GitHub CLI (`gh`) en \(serverName) para clonar desde aquí.")
                .font(.caption).foregroundStyle(.orange)
        case .notAuthenticated:
            Text("`gh` no tiene sesión en \(serverName): ejecuta `gh auth login` en su terminal.")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Reintentar") { Task { await clone.loadRepositories(force: true) } }
                    .font(.caption)
            }
        }
    }
}
