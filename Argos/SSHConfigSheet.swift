//
//  SSHConfigSheet.swift
//  Argos
//
//  Visor de ~/.ssh/config: lista los hosts definidos y permite importarlos como
//  servidores de Argos.
//

import SwiftUI

struct SSHConfigSheet: View {
    /// Servidores ya existentes, para marcar los hosts ya añadidos.
    let existingServers: [Server]
    let onImport: (SSHConfigHost) -> Void
    let onClose: () -> Void

    @State private var result: SSHConfigReader.Result = .hosts([])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            switch result {
            case .noFile:
                message("No se encontró ~/.ssh/config",
                        detail: "Crea hosts con `Host alias` en ese archivo y aparecerán aquí.",
                        icon: "doc.questionmark")
            case .failed(let error):
                message("No se pudo leer ~/.ssh/config", detail: error, icon: "exclamationmark.triangle")
            case .hosts(let all):
                let hosts = all.filter { !$0.isWildcard }
                if hosts.isEmpty {
                    message("Sin hosts", detail: "El archivo no define hosts concretos.", icon: "tray")
                } else {
                    List(hosts) { host in
                        row(host)
                    }
                    .listStyle(.inset)
                }
            }

            Divider()
            HStack {
                Text(SSHConfigReader.configPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cerrar") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .onAppear { result = SSHConfigReader.read() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hosts de ~/.ssh/config").font(.title3.weight(.semibold))
                Text("Importa cualquiera como servidor de Argos").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    @ViewBuilder
    private func row(_ host: SSHConfigHost) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias).font(.headline)
                Text(subtitle(host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let proxy = host.proxyJump, !proxy.isEmpty {
                    Label("vía \(proxy)", systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isAlreadyAdded(host) {
                Label("Añadido", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Importar") { onImport(host) }
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(_ host: SSHConfigHost) -> String {
        var parts: [String] = []
        let user = host.user ?? "?"
        let port = host.port ?? 22
        parts.append("\(user)@\(host.effectiveHost):\(port)")
        if let key = host.identityFile, !key.isEmpty {
            parts.append((key as NSString).lastPathComponent)
        }
        return parts.joined(separator: "  ·  ")
    }

    private func isAlreadyAdded(_ host: SSHConfigHost) -> Bool {
        let port = host.port ?? 22
        return existingServers.contains { $0.host == host.effectiveHost && $0.port == port }
    }

    @ViewBuilder
    private func message(_ title: String, detail: String, icon: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
