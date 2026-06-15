//
//  HostKeyVerifier.swift
//  Argos
//
//  Verificación de la host key del servidor con política Trust-On-First-Use (TOFU),
//  equivalente al `known_hosts` de OpenSSH. Sustituye a `.acceptAnything()`, que
//  dejaba la conexión expuesta a man-in-the-middle (especialmente relevante ahora
//  que la app puede ejecutar comandos privilegiados — instalar tmux — en el server).
//
//  Comportamiento:
//   - 1ª conexión a un host: se confía en la clave y se guarda su huella SHA256.
//   - Conexiones posteriores: la huella DEBE coincidir; si cambió, se aborta
//     (posible MitM o reinstalación del servidor).
//

import Foundation
import Crypto      // SHA256
import NIOCore     // ByteBuffer
import NIOSSH      // NIOSSHPublicKey, NIOSSHClientServerAuthenticationDelegate

/// Se lanza cuando la host key presentada no coincide con la previamente confiada.
struct HostKeyMismatchError: LocalizedError {
    let endpoint: String
    let storedFingerprint: String
    let presentedFingerprint: String

    var errorDescription: String? {
        "La identidad del servidor (\(endpoint)) cambió. "
        + "Esperada \(storedFingerprint), recibida \(presentedFingerprint). "
        + "Posible ataque MitM: conexión abortada. Si el cambio es legítimo "
        + "(p. ej. reinstalaste el servidor), elimina su entrada del known_hosts de Argos."
    }
}

/// Validador de host key TOFU persistido en `~/Library/Application Support/Argos/known_hosts.json`.
///
/// `@unchecked Sendable`: el estado mutable (el fichero) se protege con un `NSLock`,
/// ya que NIOSSH invoca `validateHostKey` desde un hilo del event loop.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: String
    private let storeURL: URL
    private let lock = NSLock()

    init(host: String, port: Int, storeURL: URL = TOFUHostKeyValidator.defaultStoreURL()) {
        self.endpoint = "\(host):\(port)"
        self.storeURL = storeURL
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = Self.fingerprint(of: hostKey)

        lock.lock()
        defer { lock.unlock() }

        var known = Self.load(from: storeURL)

        if let stored = known[endpoint] {
            if stored == presented {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    HostKeyMismatchError(
                        endpoint: endpoint,
                        storedFingerprint: stored,
                        presentedFingerprint: presented
                    )
                )
            }
        } else {
            // Trust on first use: registramos la huella y confiamos.
            known[endpoint] = presented
            Self.save(known, to: storeURL)
            validationCompletePromise.succeed(())
        }
    }

    // MARK: - Fingerprint

    /// Huella SHA256 en base64, con el mismo formato visual que OpenSSH (`SHA256:...`).
    static func fingerprint(of hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBuffer()
        _ = hostKey.write(to: &buffer)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let digest = SHA256.hash(data: Data(bytes))
        let base64 = Data(digest)
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    // MARK: - Persistencia (JSON: ["host:port": "SHA256:..."])

    static func defaultStoreURL() -> URL {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        let directory = base.appendingPathComponent("Argos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("known_hosts.json")
    }

    private static func load(from url: URL) -> [String: String] {
        guard
            let data = try? Data(contentsOf: url),
            let dictionary = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return dictionary
    }

    private static func save(_ dictionary: [String: String], to url: URL) {
        guard let data = try? JSONEncoder().encode(dictionary) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
