//
//  AttentionInbox.swift
//  ArgosCore
//
//  Lo que la bandeja de atención RECUERDA entre vueltas del sondeador (lógica pura):
//  - «Claude terminó» sin mirar: entra con la transición a `done` y sale al mirar esa
//    sesión, al elegirlo en la bandeja o cuando ese panel deja de estar terminado.
//  - CI fallida de un push vigilado: entra con el resultado y sale al elegirla, al
//    descartarla o con un resultado posterior que pasa.
//  El resto (Claude esperando, permisos del agente, puertos, envíos) se lee en vivo de su
//  fuente cada vez (ver `AttentionList`): no hace falta recordarlo.
//

import Foundation

struct AttentionInbox: Equatable, Sendable {

    /// Un «terminó» sin mirar.
    struct UnseenDone: Equatable, Hashable, Sendable {
        let serverID: Server.ID
        let session: String
        let window: Int

        var id: String { "done|\(serverID)|\(session)|\(window)" }
    }

    /// Un CI fallido sin atender.
    struct FailedCI: Equatable, Hashable, Sendable {
        let serverID: Server.ID
        let root: String
        let name: String
        let summary: String

        var id: String { "ci|\(serverID)|\(root)" }
    }

    private(set) var unseenDone: [String: UnseenDone] = [:]
    private(set) var failedCI: [String: FailedCI] = [:]

    /// Una vuelta de un servidor: lo que acaba de terminar, el estado actual de Claude y el
    /// CI que terminó.
    mutating func absorb(
        serverID: Server.ID,
        transitions: [ClaudeTransition],
        snapshot: ClaudeActivitySnapshot,
        ciResults: [CIResult]
    ) {
        for transition in transitions where transition.activity == .done {
            let done = UnseenDone(serverID: serverID, session: transition.session, window: transition.window)
            unseenDone[done.id] = done
        }
        // Lo que ya no está terminado (Claude volvió a trabajar, la ventana se cerró) sale.
        for (key, done) in unseenDone where done.serverID == serverID {
            if snapshot.windows(forSession: done.session)[done.window] != .done {
                unseenDone[key] = nil
            }
        }
        for result in ciResults {
            let entry = FailedCI(serverID: serverID, root: result.watch.root, name: result.watch.name, summary: result.body)
            if result.state == .failure {
                failedCI[entry.id] = entry
            } else {
                failedCI[entry.id] = nil
            }
        }
    }

    /// El usuario está mirando (o abrió) esa sesión: sus «terminó» quedan vistos.
    mutating func markSeen(serverID: Server.ID, session: String) {
        unseenDone = unseenDone.filter { $0.value.serverID != serverID || $0.value.session != session }
    }

    /// Elegido o descartado en la bandeja.
    mutating func resolve(id: String) {
        unseenDone[id] = nil
        failedCI[id] = nil
    }

    /// El servidor se borró.
    mutating func forget(serverID: Server.ID) {
        unseenDone = unseenDone.filter { $0.value.serverID != serverID }
        failedCI = failedCI.filter { $0.value.serverID != serverID }
    }
}
