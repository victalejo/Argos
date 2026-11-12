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
    private static let claudeTokenService = "com.iaportafolio.argos.claude-oauth-token"
    /// El token de Claude Code es global (suscripción del usuario del Mac), no por
    /// servidor: se guarda bajo una cuenta fija.
    private static let claudeTokenAccount = "subscription"

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

    // MARK: - Token OAuth de Claude Code (suscripción Plan Max)

    /// Guarda (o actualiza) el token de larga duración generado con `claude setup-token`.
    /// `nil` o vacío lo borra. Es global, no por servidor.
    static func setClaudeOAuthToken(_ token: String?) throws {
        try setSecret(token, service: claudeTokenService, account: claudeTokenAccount)
    }

    /// Devuelve el token OAuth de Claude Code, o `nil` si no hay ninguno.
    static func claudeOAuthToken() -> String? {
        secret(service: claudeTokenService, account: claudeTokenAccount)
    }

    /// `true` si hay un token de Claude Code guardado. No lee el secreto: en macOS,
    /// descifrarlo pide la contraseña del llavero si esta firma no está autorizada, y
    /// esto se consulta al pintar la UI.
    static func hasClaudeOAuthToken() -> Bool {
        secretExists(service: claudeTokenService, account: claudeTokenAccount)
    }

    /// Borra el token OAuth de Claude Code (idempotente).
    static func deleteClaudeOAuthToken() {
        deleteSecret(service: claudeTokenService, account: claudeTokenAccount)
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
            // Local del dispositivo: nunca se sincroniza a iCloud Keychain.
            kSecAttrSynchronizable as String: false,
        ]
        // Incluye `kSecAttrAccessible` también en el update para MIGRAR los secretos
        // guardados con otra política a la vigente al reescribir.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: service),
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibility(for: service)
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Cuándo se puede leer cada secreto.
    ///
    /// Por defecto `WhenUnlocked`: no es legible con la pantalla bloqueada. La excepción
    /// son los secretos SSH en iPhone/iPad: los avisos de «Claude terminó / espera tu
    /// permiso» se comprueban en segundo plano, casi siempre con el teléfono bloqueado, y
    /// con `WhenUnlocked` esa comprobación fallaba en silencio para los servidores con
    /// contraseña o passphrase. `AfterFirstUnlockThisDeviceOnly` los deja legibles tras
    /// el primer desbloqueo desde el arranque (lo habitual en apps con trabajo en segundo
    /// plano) y nunca salen del dispositivo. El token de Claude sigue en `WhenUnlocked`.
    private static func accessibility(for service: String) -> CFString {
        #if os(iOS)
        if service == passphraseService || service == passwordService {
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        #endif
        return kSecAttrAccessibleWhenUnlocked
    }

    /// Pasa los secretos SSH ya guardados de esos servidores a la política vigente (sin
    /// leerlos). Devuelve `false` si alguno no se pudo cambiar (p. ej. dispositivo
    /// bloqueado), para reintentarlo más tarde.
    @discardableResult
    static func applyCurrentAccessibility(toSSHSecretsOf serverIDs: [UUID]) -> Bool {
        var allApplied = true
        for service in [passphraseService, passwordService] {
            for id in serverIDs {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: id.uuidString,
                    kSecAttrSynchronizable as String: false,
                ]
                let attributes: [String: Any] = [kSecAttrAccessible as String: accessibility(for: service)]
                let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                if status != errSecSuccess && status != errSecItemNotFound {
                    Log.store.error("No se pudo actualizar la política de un secreto SSH: \(status)")
                    allApplied = false
                }
            }
        }
        return allApplied
    }

    private static func secret(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
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

    /// Comprueba si existe el ítem pidiendo solo sus atributos (sin descifrar el valor).
    private static func secretExists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.store.error("Consulta de Keychain falló: \(status)")
        }
        return status == errSecSuccess
    }

    private static func deleteSecret(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.store.error("Borrado de Keychain falló: \(status)")
        }
    }
}
