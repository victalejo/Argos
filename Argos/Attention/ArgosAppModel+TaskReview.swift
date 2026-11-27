//
//  ArgosAppModel+TaskReview.swift
//  Argos
//
//  Encargos que bloqueó el revisor automático en la bandeja «Te necesita» del Mac: la
//  entrada (del último sondeo de cada servidor) y sus dos acciones, «Subir igualmente» y
//  «Pedir a Claude que lo arregle» (las mismas que la pantalla «Encargos»).
//

import AppKit

enum AttentionReviewAction: Sendable {
    case pushAnyway
    case requestFix
}

extension ArgosAppModel {

    var attentionReviewInputs: [AttentionList.ReviewInput] {
        store.servers.flatMap { server -> [AttentionList.ReviewInput] in
            guard let vm = vms[server.id], case .loaded = vm.state else { return [] }
            return vm.reviewBlocks.map { AttentionList.ReviewInput(serverID: server.id, block: $0) }
        }
    }

    /// Abre el proyecto del encargo (su informe completo está en «Encargos»).
    func openTaskReview(serverID: Server.ID, session: String?) {
        guard let session else {
            selectedServerID = serverID
            loadSelectedIfNeeded()
            return
        }
        open(SessionHandle(serverID: serverID, sessionID: session), mode: .changes)
    }

    /// Una de las dos salidas desde la bandeja. Relee el encargo (puede haberlo resuelto
    /// otro dispositivo) y, al terminar, quita el bloqueo de la lista sin esperar al sondeo.
    func performReviewAction(_ action: AttentionReviewAction, on item: AttentionItem) {
        guard case .taskReview(let serverID, let block, _) = item.destination, let vm = vms[serverID] else { return }
        let projectPath = vm.projects.first { ClaudeUsageProjects.key(forPath: $0.path) == block.projectKey }?.path
        Task { @MainActor in
            do {
                let task = try await ClaudeTaskReviewActions.task(for: block, service: vm.service)
                switch action {
                case .pushAnyway:
                    try await ClaudeTaskReviewActions.pushAnyway(task, service: vm.service)
                case .requestFix:
                    guard let projectPath else { throw ClaudeTaskReviewError.cannotFix }
                    try await ClaudeTaskReviewActions.requestFix(
                        task, projectPath: projectPath, serverID: serverID, service: vm.service
                    )
                }
                vm.reviewBlocks.removeAll { $0 == block }
            } catch {
                Log.ssh.error("Revisor: no se pudo resolver el encargo bloqueado: \(error.userMessage, privacy: .public)")
                vm.operationError = error.userMessage
                NSSound.beep()
            }
        }
    }
}
