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

/// Abre (o recupera) el envío del proyecto y lo muestra. Cerrar la hoja mientras
/// transfiere NO lo cancela: sigue en segundo plano (ver `ProjectSyncCenter`).
struct ProjectSyncSheet: View {
    let request: ProjectSyncRequest
    let vm: SessionsViewModel
    /// Cierra el terminal y los agentes del proyecto (antes de detener su sesión).
    let closeLiveViews: (Project) -> Void
    let onClose: () -> Void

    @State private var job: ProjectSyncJob?

    var body: some View {
        Group {
            if let job {
                ProjectSyncJobView(job: job, onClose: onClose)
            } else {
                Color.clear.frame(width: 560, height: 120)
            }
        }
        .onAppear {
            let current = ProjectSyncCenter.shared.job(for: request, vm: vm, closeLiveViews: closeLiveViews)
            current.isPresented = true
            current.prepareIfNeeded()
            job = current
        }
        .onDisappear {
            guard let job else { return }
            job.isPresented = false
            ProjectSyncCenter.shared.dismiss(job)
        }
    }
}

private struct ProjectSyncJobView: View {
    @Bindable var job: ProjectSyncJob
    let onClose: () -> Void

    @State private var terminalMessage: String?

    private var project: Project { job.project }
    private var request: ProjectSyncRequest { job.request }
    private var isToMac: Bool { job.isToMac }
    private var engine: ProjectSyncEngine { job.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            footer
        }
        .padding(22)
        .frame(width: 560)
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
        switch job.phase {
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
                            Task {
                                let outcome = await LocalTerminalLauncher.openWithClaude(
                                    localRoot, remoteRoot: MacSyncStore.manifest(for: project.id)?.remoteRoot
                                )
                                terminalMessage = LocalTerminalLauncher.message(for: outcome)
                            }
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
                        job.chooseDestination(chosen)
                    }
                }
            }
            if job.hasProjectSession {
                Toggle("Detener la sesión del servidor mientras esté en el Mac (libera memoria y evita editar en dos sitios)",
                       isOn: $job.stopServerSession)
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
                    Picker("En los conflictos", selection: $job.preferMacInConflicts) {
                        Text("Conservar la versión del servidor").tag(false)
                        Text("Usar la versión del Mac").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle("Mover la copia del Mac a la Papelera al terminar", isOn: $job.trashLocalCopy)
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
            switch job.phase {
            case .running:
                Button("Cancelar envío", role: .destructive) { job.cancel() }
                Button("Seguir en segundo plano", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .help("Cierra esta ventana; la copia continúa y la fila del proyecto muestra el progreso")
            case .done, .failed:
                Button("Listo") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .readyToMac(let files, let destination):
                Button("Cancelar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Enviar al Mac") { job.startToMac(files: files, destination: destination) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil)
            case .readyToServer(let plan, let local, let manifest, let localRoot):
                Button("Cancelar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Enviar al servidor") {
                    job.startToServer(plan: plan, local: local, manifest: manifest, localRoot: localRoot)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            case .preparing:
                Button("Cancelar", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
            }
        }
    }
}
