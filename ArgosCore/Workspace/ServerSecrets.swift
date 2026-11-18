//
//  ServerSecrets.swift
//  ArgosCore
//
//  Dónde se guardan la passphrase o la contraseña de un servidor. Por defecto el
//  Llavero; los tests inyectan uno en memoria (y uno que falla).
//

import Foundation

@MainActor
protocol ServerSecretStoring {
    /// Secreto guardado para el método de `server` (`nil` si no hay).
    func secret(for server: Server) -> String?
    /// Guarda el secreto del método de `server` y borra el del otro método. Lanza si el
    /// almacén no lo acepta (entonces no se debe guardar el servidor).
    func store(_ secret: String?, for server: Server) throws
    /// Borra ambos secretos (servidor eliminado).
    func removeAll(for serverID: Server.ID)
}

/// El Llavero del sistema (`KeychainStore`).
struct KeychainServerSecrets: ServerSecretStoring {
    func secret(for server: Server) -> String? {
        switch server.authMethod {
        case .key: return KeychainStore.passphrase(for: server.id)
        case .password: return KeychainStore.password(for: server.id)
        }
    }

    func store(_ secret: String?, for server: Server) throws {
        switch server.authMethod {
        case .key:
            try KeychainStore.setPassphrase(secret, for: server.id)
            KeychainStore.deletePassword(for: server.id)
        case .password:
            try KeychainStore.setPassword(secret, for: server.id)
            KeychainStore.deletePassphrase(for: server.id)
        }
    }

    func removeAll(for serverID: Server.ID) {
        KeychainStore.deletePassphrase(for: serverID)
        KeychainStore.deletePassword(for: serverID)
    }
}

/// El servidor que se estaba editando ya no existe (se borró en otro dispositivo).
struct ServerNoLongerExistsError: LocalizedError, Equatable {
    let name: String

    var errorDescription: String? {
        String(localized: "«\(name)» se eliminó en otro dispositivo mientras lo editabas; no se ha vuelto a crear. Si lo quieres, añádelo de nuevo.")
    }
}
