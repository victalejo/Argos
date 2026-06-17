//
//  KeychainStore.swift
//  Argos
//
//  Almacén de secretos en el Keychain del usuario. Reemplaza el footgun de
//  "inyecta la passphrase en el código fuente": la passphrase de cada clave SSH
//  se guarda como un genérico de Keychain, referenciada por el id del servidor.
//

import Foundation
import Security

/// Lectura/escritura de passphrases de clave SSH en Keychain.
///
/// `service` fija el espacio de nombres; `account` es el `id` del servidor.
enum KeychainStore {

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "código \(status)"
                return "Error de Keychain: \(message)"
            }
        }
    }

    private static let passphraseService = "com.iaportafolio.argos.ssh-passphrase"
    private static let passwordService = "com.iaportafolio.argos.ssh-password"

    // MARK: - Passphrase de clave SSH

    /// Guarda (o actualiza) la passphrase de un servidor. `nil` o vacío la borra.
    static func setPassphrase(_ passphrase: String?, for serverID: UUID) throws {
        try setSecret(passphrase, service: passphraseService, account: serverID.uuidString)
    }

    /// Devuelve la passphrase de un servidor, o `nil` si no hay ninguna guardada.
    static func passphrase(for serverID: UUID) -> String? {
        secret(service: passphraseService, account: serverID.uuidString)
    }

    /// Borra la passphrase de un servidor (idempotente).
    static func deletePassphrase(for serverID: UUID) {
        deleteSecret(service: passphraseService, account: serverID.uuidString)
    }

    // MARK: - Contraseña de login SSH

    /// Guarda (o actualiza) la contraseña de login de un servidor. `nil` o vacío la borra.
    static func setPassword(_ password: String?, for serverID: UUID) throws {
        try setSecret(password, service: passwordService, account: serverID.uuidString)
    }

    /// Devuelve la contraseña de login de un servidor, o `nil` si no hay ninguna.
    static func password(for serverID: UUID) -> String? {
        secret(service: passwordService, account: serverID.uuidString)
    }

    /// Borra la contraseña de login de un servidor (idempotente).
    static func deletePassword(for serverID: UUID) {
        deleteSecret(service: passwordService, account: serverID.uuidString)
    }

    // MARK: - Núcleo genérico (service + account)

    private static func setSecret(_ value: String?, service: String, account: String) throws {
        guard let value, !value.isEmpty else {
            deleteSecret(service: service, account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    private static func secret(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.store.error("Lectura de Keychain falló: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteSecret(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.store.error("Borrado de Keychain falló: \(status)")
        }
    }
}
