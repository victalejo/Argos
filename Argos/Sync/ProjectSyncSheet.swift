//
//  ProjectSyncSheet.swift
//  Argos
//
//  "Enviar al Mac" y "Enviar al servidor" de un proyecto: resumen antes de tocar nada,
//  progreso durante la transferencia y, a la vuelta, conflictos a decidir.
//

import AppKit
import SwiftUI

/// Qué envío abrir (y en qué servidor).
enum ProjectSyncRequest: Identifiable {
    case toMac(Server, Project)
    case toServer(Server, Project)

    var id: String {
        switch self {
        case .toMac(_, let project): return "mac-\(project.id)"
        case .toServer(_, let project): return "server-\(project.id)"
        }
    }

    var server: Server {
        switch self {
        case .toMac(let server, _), .toServer(let server, _): return server
        }
    }

    var project: Project {
        switch self {
        case .toMac(_, let project), .toServer(_, let project): return project
        }
    }
}

struct ProjectSyncSheet: View {
    let request: ProjectSyncRequest
    let vm: SessionsViewModel
    /// Cierra el terminal y los agentes del proyecto (antes de detener su sesión).
    let closeLiveViews: (Project) -> Void
    let onClose: () -> Void

    private enum Phase {
        case preparing
        case readyToMac(files: [SyncFile], destination: URL?)
        case readyToServer(plan: SyncPlan, local: [SyncFile], manifest: SyncManifest, localRoot: URL)
        case running
        case done(String, localRoot: URL?)
        case failed(String)
    }

    @State private var phase: Phase = .preparing
    @State private var engine = ProjectSyncEngine()
    @State private var stopServerSession = true
    @State private var preferMacInConflicts = false
    @State private var trashLocalCopy = false
    @State private var terminalMessage: String?
    @State private var task: Task<Void, Never>?

    private var project: Project { request.project }
    private var isToMac: Bool { if case .toMac = request { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            footer
        }
        .padding(22)
        .frame(width: 560)
        .task { await prepare() }
        .onDisappear { task?.cancel() }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: isToMac ? "laptopcomputer.and.arrow.down" : "icloud.and.arrow.up")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(isToMac ? "Enviar \(project.name) al Mac" : "Enviar \(project.name) al servidor")
                    .font(.title2.weight(.semibold))
                Text(isToMac
                     ? "Se copia la carpeta del servidor a este Mac para trabajar en un dispositivo real. Al terminar, la devuelves con «Enviar al servidor»."
                     : "Se suben a \(request.server.name) los cambios que hiciste en el Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Contenido

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(isToMac ? "Leyendo los archivos del proyecto…" : "Comparando el Mac con el servidor…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)

        case .readyToMac(let files, let destination):
            toMacSummary(files: files, destination: destination)

        case .readyToServer(let plan, _, _, _):
            toServerSummary(plan)

        case .running:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: engine.fraction)
                HStack {
                    Text("\(engine.doneFiles) de \(engine.totalFiles) archivos")
                    Spacer()
                    if engine.totalBytes > 0 {
                        Text("\(ResourceFormat.kilobytes(Int(engine.doneBytes / 1024))) de \(ResourceFormat.kilobytes(Int(engine.totalBytes / 1024)))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                if let path = engine.currentPath {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }

        case .done(let message, let localRoot):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let localRoot, isToMac {
                    HStack {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([localRoot])
                        } label: { Label("Mostrar en Finder", systemImage: "folder") }
                        Button {
                            terminalMessage = LocalTerminalLauncher.message(for: LocalTerminalLauncher.openWithClaude(localRoot))
                        } label: { Label("Abrir en Terminal con Claude Code", systemImage: "terminal") }
                        if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
                            Button {
                                NSWorkspace.shared.open([localRoot], withApplicationAt: vscode, configuration: .init())
                            } label: { Label("Abrir en VS Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                        }
                    }
                    if let terminalMessage {
                        Text(terminalMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toMacSummary(files: [SyncFile], destination: URL?) -> some View {
        let bytes = files.reduce(UInt64(0)) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 12) {
            summaryRow(files.isEmpty ? "folder" : "doc.on.doc", SyncSummaryText.toMac(
                fileCount: files.count, kilobytes: ResourceFormat.kilobytes(Int(bytes / 1024))
            ))
            summaryRow("nosign", "Sin node_modules, builds ni cachés (se regeneran en el Mac). Incluye .git y .env.")
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                if let destination {
                    Text(destination.appendingPathComponent((project.path as NSString).lastPathComponent).path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text("Elige dónde guardar los proyectos en este Mac").foregroundStyle(.secondary)
                }
                Spacer()
                Button(destination == nil ? "Elegir carpeta…" : "Cambiar…") {
                    if let chosen = MacSyncStore.chooseDestination() {
                        phase = .readyToMac(files: files, destination: chosen)
                    }
                }
            }
            if vm.session(withID: project.sessionName) != nil {
                Toggle("Detener la sesión del servidor mientras esté en el Mac (libera memoria y evita editar en dos sitios)",
                       isOn: $stopServerSession)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func toServerSummary(_ plan: SyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if plan.isEmpty && plan.keptServerChanges.isEmpty {
                summaryRow("checkmark.circle", "No hay cambios: el Mac y el servidor están iguales.")
            }
            if !plan.uploads.isEmpty {
                summaryRow("arrow.up.doc", "\(plan.uploads.count) archivos nuevos o modificados se subirán")
            }
            if !plan.deletions.isEmpty {
                summaryRow("trash", "\(plan.deletions.count) archivos borrados en el Mac se borrarán en el servidor")
            }
            if !plan.keptServerChanges.isEmpty {
                summaryRow("server.rack", "\(plan.keptServerChanges.count) cambios hechos en el servidor mientras tanto se conservan")
            }
            if !plan.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(plan.conflicts.count) conflictos: cambiaron en el Mac y en el servidor", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.medium))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(plan.conflicts, id: \.self) { conflict in
                                Text("• \(conflict.path) — \(describe(conflict.kind))")
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    Picker("En los conflictos", selection: $preferMacInConflicts) {
                        Text("Conservar la versión del servidor").tag(false)
                        Text("Usar la versión del Mac").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle("Mover la copia del Mac a la Papelera al terminar", isOn: $trashLocalCopy)
                .toggleStyle(.checkbox)
        }
    }

    private func summaryRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func describe(_ kind: SyncConflict.Kind) -> String {
        switch kind {
        case .bothModified: return "modificado en ambos"
        case .deletedOnMacModifiedOnServer: return "borrado en el Mac, modificado en el servidor"
        case .modifiedOnMacDeletedOnServer: return "modificado en el Mac, borrado en el servidor"
        }
    }

    // MARK: - Pie

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .running:
                Button("Cancelar", role: .cancel) { task?.cancel() }
            case .done, .failed:
                Button("Listo") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .readyToMac(let files, let destination):
                Button("Cancelar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Enviar al Mac") { startToMac(files: files, destination: destination) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil)
            case .readyToServer(let plan, let local, let manifest, let localRoot):
                Button("Cancelar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Enviar al servidor") {
                    startToServer(plan: plan, local: local, manifest: manifest, localRoot: localRoot)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            case .preparing:
                Button("Cancelar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Flujo

    private func prepare() async {
        do {
            switch request {
            case .toMac:
                let files = try await vm.service.syncFileList(root: project.path)
                phase = .readyToMac(files: files, destination: MacSyncStore.destination())
            case .toServer:
                guard let manifest = MacSyncStore.manifest(for: project.id),
                      let localRoot = MacSyncStore.localFolder(of: manifest) else {
                    phase = .failed("Este Mac no tiene la copia de \(project.name). Envíalo al servidor desde el Mac donde lo tienes.")
                    return
                }
                let (plan, local) = try await MacSyncStore.withAccess(to: localRoot) {
                    try await engine.plan(manifest: manifest, localRoot: localRoot, service: vm.service)
                }
                phase = .readyToServer(plan: plan, local: local, manifest: manifest, localRoot: localRoot)
            }
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    private func startToMac(files: [SyncFile], destination: URL?) {
        guard let destination else { return }
        phase = .running
        task = Task {
            do {
                let localRoot = destination.appendingPathComponent((project.path as NSString).lastPathComponent, isDirectory: true)
                let state = try await MacSyncStore.withAccess(to: destination) {
                    try await engine.download(files: files, from: project.path, to: localRoot, service: vm.service)
                }
                var manifest = SyncManifest(
                    projectID: project.id,
                    serverID: request.server.id,
                    remoteRoot: project.path,
                    localPath: localRoot.path,
                    createdAt: Date(),
                    files: state
                )
                manifest.localBookmark = await MacSyncStore.withAccess(to: destination) {
                    try? localRoot.bookmarkData(options: .withSecurityScope)
                }
                try MacSyncStore.save(manifest)
                try await vm.setMacCheckout(
                    MacCheckout(macName: MacSyncStore.macName, macID: MacSyncStore.macID, date: Date()),
                    for: project
                )
                if stopServerSession, vm.session(withID: project.sessionName) != nil {
                    closeLiveViews(project)
                    try? await vm.stopProject(project)
                }
                await vm.refresh()
                phase = .done("\(files.count) archivos copiados. Trabaja en el Mac y, al terminar, usa «Enviar al servidor».", localRoot: localRoot)
            } catch is CancellationError {
                phase = .failed("Cancelado. La copia del Mac puede haber quedado a medias: bórrala antes de reintentar.")
            } catch {
                phase = .failed(error.userMessage)
            }
        }
    }

    private func startToServer(plan: SyncPlan, local: [SyncFile], manifest: SyncManifest, localRoot: URL) {
        let resolved = SyncPlanner.resolving(plan, preferMac: preferMacInConflicts, local: local)
        phase = .running
        task = Task {
            do {
                try await MacSyncStore.withAccess(to: localRoot) {
                    try await engine.upload(plan: resolved, remoteRoot: manifest.remoteRoot, localRoot: localRoot, service: vm.service)
                }
                try await vm.setMacCheckout(nil, for: project)
                MacSyncStore.deleteManifest(for: project.id)
                if trashLocalCopy {
                    await MacSyncStore.withAccess(to: localRoot) {
                        try? FileManager.default.trashItem(at: localRoot, resultingItemURL: nil)
                    }
                }
                await vm.refresh()
                phase = .done(
                    "Listo: \(resolved.uploads.count) archivos subidos y \(resolved.deletions.count) borrados en \(request.server.name). "
                    + "El proyecto vuelve a estar en el servidor.",
                    localRoot: nil
                )
            } catch is CancellationError {
                phase = .failed("Cancelado. Parte de los cambios pueden haberse subido; vuelve a «Enviar al servidor» para terminar.")
            } catch {
                phase = .failed(error.userMessage)
            }
        }
    }
}
