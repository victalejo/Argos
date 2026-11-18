//
//  ServerHub+DeviceKey.swift
//  ArgosiOS
//
//  «Usar una clave de este iPhone»: con un servidor al que ya se entra por contraseña,
//  crea un par Ed25519 en el dispositivo, autoriza la pública en `authorized_keys`
//  (con la conexión por contraseña) y COMPRUEBA que el servidor acepta la clave antes de
//  pasar el servidor a autenticación por clave y borrar la contraseña. Si la prueba
//  falla, retira la clave del servidor y todo queda como estaba.
//

import Foundation

enum DeviceKeyInstallError: LocalizedError {
    case notPasswordServer
    case keyRejected(String)

    var errorDescription: String? {
        switch self {
        case .notPasswordServer:
            return String(localized: "Este servidor ya usa una clave SSH.")
        case .keyRejected(let detail):
            return String(localized: "Se añadió la clave a ~/.ssh/authorized_keys, pero el servidor no la aceptó (\(detail)). Se ha retirado y se sigue usando la contraseña. Comprueba que el servidor permite claves (PubkeyAuthentication yes en sshd_config) y que ~/.ssh no tiene permisos de escritura para otros.")
        }
    }
}

extension ServerHub {
    /// Pasa `server` (por contraseña) a una clave creada en este dispositivo. Devuelve el
    /// servidor ya guardado con la clave.
    @discardableResult
    func installDeviceKey(on server: Server) async throws -> Server {
        guard server.authMethod == .password else { throw DeviceKeyInstallError.notPasswordServer }
        let pair = DeviceKeyPair.generate()
        let service = viewModel(for: server).service
        try await service.authorizeKey(line: pair.authorizedKeyLine)

        // Prueba con la clave nueva, en una copia temporal (aún no se toca lo guardado).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var candidate = server
        candidate.authMethod = .key
        candidate.requiresPassphrase = false
        do {
            candidate.privateKeyPath = try ImportedKeyStore.store(Data(pair.privateKeyPEM.utf8), for: server.id, in: scratch)
            let probe = SSHService(configuration: SSHService.Configuration(server: candidate, passphrase: nil))
            defer { Task { await probe.disconnect() } }
            _ = try await probe.testConnection()
        } catch {
            Log.ssh.error("La clave del dispositivo no funcionó en \(server.name, privacy: .private): \(error.userMessage, privacy: .public)")
            do {
                try await service.revokeKey(comment: pair.comment)
            } catch {
                Log.ssh.error("No se pudo retirar la clave \(pair.comment, privacy: .public): \(error.userMessage, privacy: .public)")
            }
            throw DeviceKeyInstallError.keyRejected(error.userMessage)
        }

        // Funciona: se guarda de verdad y se deja de usar la contraseña.
        candidate.privateKeyPath = try ImportedKeyStore.store(Data(pair.privateKeyPEM.utf8), for: server.id)
        do {
            try save(candidate, secret: nil, isNew: false)
        } catch {
            ImportedKeyStore.remove(for: server.id)
            throw error
        }
        Log.ssh.info("Servidor \(server.name, privacy: .private) pasado a clave del dispositivo (\(pair.comment, privacy: .public))")
        return candidate
    }
}
