//
//  ServerSyncDocument.swift
//  Argos
//
//  Sincronización por iCloud entre Mac, iPhone e iPad (lógica pura, testeable).
//
//  Qué viaja: la DEFINICIÓN de los servidores (nombre, host, puerto, usuario, método)
//  y las huellas confiadas (TOFU). Qué NO viaja nunca: contraseñas, passphrases, claves
//  privadas ni los bookmarks de archivos (son de cada dispositivo). Tras sincronizar,
//  cada dispositivo pide la contraseña o la clave la primera vez que se conecta.
//
//  Fusión: por servidor gana el cambio más reciente; un borrado (lápida) gana si es
//  posterior a la última edición. Las huellas igual (olvidar una huella tras reinstalar
//  un servidor se propaga), salvo que una huella remota NUNCA sustituye a una local
//  DISTINTA, y solo se olvida aquí la MISMA huella que se olvidó allí.
//
//  Defensa ante un iCloud manipulado: las fechas del futuro se recortan a «ahora», y si
//  una edición remota cambia host, puerto, usuario o método de un servidor, aquí se
//  borran sus secretos (`credentialsToInvalidate`): la contraseña nunca viaja a un host
//  que el usuario no eligió en ESTE dispositivo.
//

import Foundation

struct SyncedServer: Codable, Equatable, Sendable {
    var server: Server
    var modifiedAt: Date
}

struct TrustedHost: Codable, Equatable, Sendable {
    var fingerprint: String
    var trustedAt: Date
}

/// Lápida de una huella olvidada: CUÁL se olvidó y cuándo.
struct ForgottenHost: Codable, Equatable, Sendable {
    var fingerprint: String
    var forgottenAt: Date
}

struct ServerSyncDocument: Codable, Equatable, Sendable {
    var version = 1
    /// Por id de servidor (uuidString).
    var servers: [String: SyncedServer] = [:]
    /// Lápidas: id → fecha de borrado.
    var deleted: [String: Date] = [:]
    /// Huellas confiadas por "host:puerto".
    var knownHosts: [String: TrustedHost] = [:]
    /// Huellas olvidadas (lápidas) por "host:puerto".
    var forgottenHosts: [String: ForgottenHost] = [:]

    static let empty = ServerSyncDocument()

    /// Las lápidas más viejas que esto se olvidan (todos los dispositivos ya las vieron).
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600

    /// Servidores vivos, en orden estable (por nombre).
    var liveServers: [Server] {
        servers.values.map(\.server).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum ServerSync {

    /// Copia del servidor apta para iCloud: sin datos propios del dispositivo.
    static func portable(_ server: Server) -> Server {
        var copy = server
        copy.privateKeyBookmark = nil
        return copy
    }

    /// Documento que describe el estado LOCAL, conservando la fecha de los servidores que
    /// no cambiaron desde `previous` (lo último sincronizado) y fechando ahora lo nuevo,
    /// lo editado y lo borrado.
    static func localDocument(
        servers: [Server],
        knownHosts: [String: String],
        previous: ServerSyncDocument,
        now: Date = Date()
    ) -> ServerSyncDocument {
        var document = ServerSyncDocument(deleted: previous.deleted, forgottenHosts: previous.forgottenHosts)
        for server in servers {
            let portable = portable(server)
            let key = server.id.uuidString
            if let old = previous.servers[key], old.server == portable {
                document.servers[key] = old
            } else {
                document.servers[key] = SyncedServer(server: portable, modifiedAt: now)
            }
            document.deleted[key] = nil
        }
        for key in previous.servers.keys where document.servers[key] == nil {
            document.deleted[key] = now
        }
        for (endpoint, fingerprint) in knownHosts {
            if let old = previous.knownHosts[endpoint], old.fingerprint == fingerprint {
                document.knownHosts[endpoint] = old
            } else {
                document.knownHosts[endpoint] = TrustedHost(fingerprint: fingerprint, trustedAt: now)
            }
            document.forgottenHosts[endpoint] = nil
        }
        for (endpoint, old) in previous.knownHosts where knownHosts[endpoint] == nil {
            document.forgottenHosts[endpoint] = ForgottenHost(fingerprint: old.fingerprint, forgottenAt: now)
        }
        return document
    }

    static func merge(
        local: ServerSyncDocument,
        remote untrusted: ServerSyncDocument,
        now: Date = Date()
    ) -> ServerSyncDocument {
        let remote = clampingFutureDates(untrusted, now: now)
        var merged = ServerSyncDocument()

        // Lápidas: la más reciente de cada id; las caducadas se olvidan.
        for (key, date) in local.deleted.merging(remote.deleted, uniquingKeysWith: max)
        where now.timeIntervalSince(date) < ServerSyncDocument.tombstoneLifetime {
            merged.deleted[key] = date
        }

        // Servidores: gana la edición más reciente; empate → la local.
        for key in Set(local.servers.keys).union(remote.servers.keys) {
            let candidates = [local.servers[key], remote.servers[key]].compactMap { $0 }
            guard let newest = candidates.max(by: { $0.modifiedAt < $1.modifiedAt }) else { continue }
            let winner = local.servers[key].flatMap { $0.modifiedAt >= newest.modifiedAt ? $0 : nil } ?? newest
            if let deletedAt = merged.deleted[key], deletedAt >= winner.modifiedAt { continue }
            merged.servers[key] = winner
            merged.deleted[key] = nil
        }

        // Huellas.
        let forgotten = local.forgottenHosts.merging(remote.forgottenHosts) { $0.forgottenAt >= $1.forgottenAt ? $0 : $1 }
        for (endpoint, tombstone) in forgotten
        where now.timeIntervalSince(tombstone.forgottenAt) < ServerSyncDocument.tombstoneLifetime {
            merged.forgottenHosts[endpoint] = tombstone
        }
        for endpoint in Set(local.knownHosts.keys).union(remote.knownHosts.keys) {
            let mine = local.knownHosts[endpoint], theirs = remote.knownHosts[endpoint]
            let winner: TrustedHost?
            switch (mine, theirs) {
            case let (mine?, theirs?) where mine.fingerprint != theirs.fingerprint:
                winner = mine // una huella distinta de iCloud nunca reemplaza la local
            case let (mine?, theirs?):
                winner = mine.trustedAt >= theirs.trustedAt ? mine : theirs
            default:
                winner = mine ?? theirs
            }
            guard let winner else { continue }
            // Una lápida solo borra la MISMA huella que se olvidó (y posterior a confiarla).
            if let tombstone = merged.forgottenHosts[endpoint],
               tombstone.fingerprint == winner.fingerprint,
               tombstone.forgottenAt >= winner.trustedAt { continue }
            merged.knownHosts[endpoint] = winner
            merged.forgottenHosts[endpoint] = nil
        }
        return merged
    }

    /// Lista local resultante: los servidores del documento, conservando el orden local
    /// y los datos propios de este dispositivo (bookmarks) de los que ya existían.
    static func applying(_ document: ServerSyncDocument, to local: [Server]) -> [Server] {
        let byID = Dictionary(uniqueKeysWithValues: document.servers.map { ($0.key, $0.value.server) })
        var result: [Server] = local.compactMap { existing in
            guard var synced = byID[existing.id.uuidString] else { return nil }
            synced.privateKeyBookmark = existing.privateKeyBookmark
            if synced.privateKeyPath == existing.privateKeyPath {
                return synced
            }
            // La ruta cambió en otro dispositivo: el bookmark local ya no corresponde.
            synced.privateKeyBookmark = nil
            return synced
        }
        let present = Set(result.map(\.id))
        result += document.liveServers.filter { !present.contains($0.id) }
        return result
    }

    /// Cambios para el almacén local de huellas: las que faltan (nunca reemplaza una
    /// existente) y las que se olvidaron en otro dispositivo.
    static func hostChanges(
        in document: ServerSyncDocument,
        local: [String: String]
    ) -> (add: [String: String], forget: [String]) {
        let add = document.knownHosts
            .filter { local[$0.key] == nil }
            .mapValues(\.fingerprint)
        let forget = local.filter { endpoint, fingerprint in
            document.knownHosts[endpoint] == nil && document.forgottenHosts[endpoint]?.fingerprint == fingerprint
        }.keys
        return (add, forget.sorted())
    }

    /// Servidores cuyos secretos locales hay que borrar: los que una edición remota
    /// cambió de host, puerto, usuario o método (si no, la contraseña guardada aquí se
    /// enviaría a un destino que este dispositivo nunca confirmó).
    static func credentialsToInvalidate(before: [Server], after: [Server]) -> [Server.ID] {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        return after.compactMap { new in
            guard let previous = old[new.id] else { return nil }
            let changed = previous.host != new.host || previous.port != new.port
                || previous.username != new.username || previous.authMethod != new.authMethod
            return changed ? new.id : nil
        }
    }

    /// Un dispositivo con el reloj adelantado (o un documento manipulado) no puede
    /// «ganar» siempre: ninguna fecha remota cuenta como posterior a ahora.
    static func clampingFutureDates(_ document: ServerSyncDocument, now: Date) -> ServerSyncDocument {
        var copy = document
        copy.servers = copy.servers.mapValues { var s = $0; s.modifiedAt = min(s.modifiedAt, now); return s }
        copy.deleted = copy.deleted.mapValues { min($0, now) }
        copy.knownHosts = copy.knownHosts.mapValues { var h = $0; h.trustedAt = min(h.trustedAt, now); return h }
        copy.forgottenHosts = copy.forgottenHosts.mapValues { var f = $0; f.forgottenAt = min(f.forgottenAt, now); return f }
        return copy
    }

    // MARK: - Codificación (iCloud clave-valor guarda Data)

    static func encode(_ document: ServerSyncDocument) throws -> Data {
        try JSONEncoder.projects.encode(document)
    }

    static func decode(_ data: Data?) -> ServerSyncDocument? {
        guard let data else { return nil }
        return try? JSONDecoder.projects.decode(ServerSyncDocument.self, from: data)
    }
}
