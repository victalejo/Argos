//
//  ServerServiceFactory.swift
//  Argos
//
//  Crea el `SSHService` de un servidor con sus secretos de Keychain (passphrase de la
//  clave o contraseña de login). Compartido por Mac e iPhone/iPad.
//

import Foundation

extension Server {
    /// Servicio SSH listo para conectar, con el secreto que corresponda leído del Keychain.
    func makeService() -> SSHService {
        switch authMethod {
        case .key:
            let passphrase = requiresPassphrase ? KeychainStore.passphrase(for: id) : nil
            var server = self
            server.privateKeyPath = ImportedKeyStore.resolvedPath(privateKeyPath, for: id)
            return SSHService(configuration: SSHService.Configuration(server: server, passphrase: passphrase))
        case .password:
            return SSHService(configuration: SSHService.Configuration(server: self, password: KeychainStore.password(for: id)))
        }
    }
}
