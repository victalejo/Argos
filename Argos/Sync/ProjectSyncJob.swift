//
//  ProjectSyncJob.swift
//  Argos
//
//  Un envío ("Enviar al Mac" / "Enviar al servidor") con vida PROPIA, independiente de
//  la hoja que lo muestra: la hoja puede cerrarse ("Seguir en segundo plano") y la
//  transferencia continúa; la fila del proyecto muestra el progreso y reabre la hoja.
//  `ProjectSyncCenter` guarda un envío por proyecto.
//

import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class ProjectSyncJob {

    enum Phase {
        case preparing
        case readyToMac(files: [SyncFile], destination: URL?)
        case readyToServer(plan: SyncPlan, local: [SyncFile], manifest: SyncManifest, localRoot: URL)
        case running
        case done(String, localRoot: URL?)
        case failed(String)
    }

    let request: ProjectSyncRequest
    let engine = ProjectSyncEngine()
    private(set) var phase: Phase = .preparing

    var stopServerSession = true
    var preferMacInConflicts = false
    var trashLocalCopy = false
    /// Si la hoja está a la vista (si no, al terminar se avisa con una notificación).
    var isPresented = false

    @ObservationIgnored private let vm: SessionsViewModel
    @ObservationIgnored private let closeLiveViews: (Project) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var hasPrepared = false

    init(request: ProjectSyncRequest, vm: SessionsViewModel, closeLiveViews: @escaping (Project) -> Void) {
        self.request = request
        self.vm = vm
        self.closeLiveViews = closeLiveViews
    }

    var project: Project { request.project }
    var isToMac: Bool { if case .toMac = request { return true } else { return false } }
    var isRunning: Bool { if case .running = phase { return true } else { return false } }
    var hasProjectSession: Bool { vm.session(withID: project.sessionName) != nil }

    func cancel() { task?.cancel() }

    func chooseDestination(_ destination: URL) {
        guard case .readyToMac(let files, _) = phase else { return }
        phase = .readyToMac(files: files, destination: destination)
    }

    // MARK: - Preparación

    func prepareIfNeeded() {
        guard !hasPrepared else { return }
        hasPrepared = true
        task = Task { await prepare() }
    }

    private func prepare() async {
        do {
            switch request {
            case .toMac:
                let files = try await vm.service.syncFileList(root: project.path)
                try Task.checkCancellation()
                phase = .readyToMac(files: files, destination: MacSyncStore.destination())
            case .toServer:
                guard let manifest = try MacSyncStore.loadManifest(for: project.id),
                      let localRoot = MacSyncStore.localFolder(of: manifest) else {
                    phase = .failed("Este Mac no tiene la copia de \(project.name). Envíalo al servidor desde el Mac donde lo tienes.")
                    return
                }
                let exists = await MacSyncStore.withAccess(to: localRoot) {
                    FileManager.default.fileExists(atPath: localRoot.path)
                }
                guard exists else {
                    Log.store.error("Copia local de \(self.project.name, privacy: .public) no encontrada en \(localRoot.path, privacy: .public)")
                    phase = .failed("La copia de \(project.name) ya no está en \(localRoot.path) (¿se movió o se borró?).")
                    return
                }
                let (plan, local) = try await MacSyncStore.withAccess(to: localRoot) {
                    try await engine.plan(manifest: manifest, localRoot: localRoot, service: vm.service)
                }
                try Task.checkCancellation()
                phase = .readyToServer(plan: plan, local: local, manifest: manifest, localRoot: localRoot)
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.userMessage)
        }
    }

    // MARK: - Servidor → Mac

    func startToMac(files: [SyncFile], destination: URL?) {
        guard let destination else { return }
        phase = .running
        task = Task {
            do {
                let message = try await runToMac(files: files, destination: destination)
                finish(.done(message.text, localRoot: message.localRoot))
            } catch is CancellationError {
                finish(.failed("Cancelado. La copia del Mac puede haber quedado a medias: bórrala antes de reintentar."))
            } catch {
                finish(.failed(error.userMessage))
            }
        }
    }

    private func runToMac(files: [SyncFile], destination: URL) async throws -> (text: String, localRoot: URL) {
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
        if stopServerSession, hasProjectSession {
            closeLiveViews(project)
            try? await vm.stopProject(project)
        }
        await vm.refresh()
        return ("\(files.count) archivos copiados. Trabaja en el Mac y, al terminar, usa «Enviar al servidor».", localRoot)
    }

    // MARK: - Mac → servidor

    func startToServer(plan: SyncPlan, local: [SyncFile], manifest: SyncManifest, localRoot: URL) {
        let resolved = SyncPlanner.resolving(plan, preferMac: preferMacInConflicts, local: local)
        phase = .running
        task = Task {
            do {
                try await runToServer(resolved, manifest: manifest, localRoot: localRoot)
                finish(.done(
                    "Listo: \(resolved.uploads.count) archivos subidos y \(resolved.deletions.count) borrados en \(request.server.name). "
                    + "El proyecto vuelve a estar en el servidor.",
                    localRoot: nil
                ))
            } catch is CancellationError {
                finish(.failed("Cancelado. Parte de los cambios pueden haberse subido; vuelve a «Enviar al servidor» para terminar."))
            } catch {
                finish(.failed(error.userMessage))
            }
        }
    }

    private func runToServer(_ plan: SyncPlan, manifest: SyncManifest, localRoot: URL) async throws {
        try await MacSyncStore.withAccess(to: localRoot) {
            try await engine.upload(plan: plan, remoteRoot: manifest.remoteRoot, localRoot: localRoot, service: vm.service)
        }
        try await vm.setMacCheckout(nil, for: project)
        MacSyncStore.deleteManifest(for: project.id)
        if trashLocalCopy {
            await MacSyncStore.withAccess(to: localRoot) {
                try? FileManager.default.trashItem(at: localRoot, resultingItemURL: nil)
            }
        }
        await vm.refresh()
    }

    // MARK: - Fin

    private func finish(_ final: Phase) {
        phase = final
        task = nil
        if !isPresented { notifyFinished() }
    }

    /// Aviso de macOS si el envío terminó con la hoja cerrada (en primer plano basta
    /// el indicador de la fila del proyecto).
    private func notifyFinished() {
        let content = UNMutableNotificationContent()
        switch phase {
        case .done(let message, _):
            content.title = isToMac ? "\(project.name) ya está en el Mac" : "\(project.name) volvió al servidor"
            content.body = message
        case .failed(let message):
            content.title = "No se pudo enviar \(project.name)"
            content.body = message
        default:
            return
        }
        content.sound = .default
        let notification = UNNotificationRequest(identifier: "sync-\(project.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(notification) { error in
            if let error {
                Log.store.error("Notificación de envío: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Envíos vivos, uno por proyecto. Sobreviven a la hoja que los muestra.
@MainActor
@Observable
final class ProjectSyncCenter {
    static let shared = ProjectSyncCenter()

    private(set) var jobs: [Project.ID: ProjectSyncJob] = [:]

    private init() {}

    func job(forProject id: Project.ID) -> ProjectSyncJob? { jobs[id] }

    /// El envío en curso del proyecto (si lo hay) o uno nuevo para `request`.
    func job(
        for request: ProjectSyncRequest,
        vm: SessionsViewModel,
        closeLiveViews: @escaping (Project) -> Void
    ) -> ProjectSyncJob {
        if let existing = jobs[request.project.id], existing.isRunning || existing.request.id == request.id {
            return existing
        }
        let job = ProjectSyncJob(request: request, vm: vm, closeLiveViews: closeLiveViews)
        jobs[request.project.id] = job
        ClaudeActivityNotifier.shared.requestAuthorizationIfNeeded()
        return job
    }

    /// Olvida el envío al cerrar su hoja, salvo que siga transfiriendo.
    func dismiss(_ job: ProjectSyncJob) {
        guard !job.isRunning else { return }
        job.cancel()
        if jobs[job.project.id] === job {
            jobs[job.project.id] = nil
        }
    }
}
