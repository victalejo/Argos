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
import os
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

    /// Lock PROCESS-WIDE: distintos validadores (p. ej. al conectar a varios
    /// servidores a la vez en modo multi-servidor) comparten el MISMO fichero
    /// known_hosts.json, así que la exclusión debe ser estática, no por instancia.
    private static let fileLock = NSLock()

    init(host: String, port: Int, storeURL: URL = TOFUHostKeyValidator.defaultStoreURL()) {
        self.endpoint = "\(host):\(port)"
        self.storeURL = storeURL
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = Self.fingerprint(of: hostKey)

        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

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

    /// Todas las huellas confiadas ("host:puerto" → "SHA256:…"), para sincronizarlas.
    static func allTrusted(storeURL: URL = defaultStoreURL()) -> [String: String] {
        fileLock.lock()
        defer { fileLock.unlock() }
        return load(from: storeURL)
    }

    /// Añade huellas que llegan de otro dispositivo. NUNCA reemplaza una existente.
    static func trust(_ entries: [String: String], storeURL: URL = defaultStoreURL()) {
        guard !entries.isEmpty else { return }
        fileLock.lock()
        defer { fileLock.unlock() }
        var known = load(from: storeURL)
        let before = known.count
        known.merge(entries) { existing, _ in existing }
        if known.count != before { save(known, to: storeURL) }
    }

    /// Olvida huellas por "host:puerto" (olvidadas en otro dispositivo).
    static func forget(endpoints: [String], storeURL: URL = defaultStoreURL()) {
        guard !endpoints.isEmpty else { return }
        fileLock.lock()
        defer { fileLock.unlock() }
        var known = load(from: storeURL)
        let before = known.count
        endpoints.forEach { known.removeValue(forKey: $0) }
        if known.count != before { save(known, to: storeURL) }
    }

    /// `true` si ya hay una huella confiada para el endpoint (p. ej. para saber si una
    /// prueba de conexión la registró por primera vez y hay que deshacerlo).
    static func isTrusted(host: String, port: Int, storeURL: URL = defaultStoreURL()) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        return load(from: storeURL)["\(host):\(port)"] != nil
    }

    /// Huella confiada para el endpoint, si la hay (se pasa al iPhone en el QR).
    static func trustedFingerprint(host: String, port: Int, storeURL: URL = defaultStoreURL()) -> String? {
        fileLock.lock()
        defer { fileLock.unlock() }
        return load(from: storeURL)["\(host):\(port)"]
    }

    /// Fija la huella confiada de un endpoint (la que verificó el Mac, recibida por QR),
    /// en vez de confiar en la que presente el servidor en la primera conexión.
    /// NUNCA sustituye una huella distinta ya confiada: un QR o enlace no debe poder
    /// cambiar la identidad de un servidor conocido (abriría la puerta a un MitM).
    /// Devuelve `false` si había otra huella (que se conserva).
    @discardableResult
    static func trustIfUnknown(fingerprint: String, host: String, port: Int, storeURL: URL = defaultStoreURL()) -> Bool {
        let endpoint = "\(host):\(port)"
        fileLock.lock()
        defer { fileLock.unlock() }
        var known = load(from: storeURL)
        if let previous = known[endpoint] {
            guard previous == fingerprint else {
                Log.hostKey.error("Huella recibida por QR para \(endpoint, privacy: .public) distinta de la confiada: se conserva la existente.")
                return false
            }
            return true
        }
        known[endpoint] = fingerprint
        save(known, to: storeURL)
        return true
    }

    /// Olvida la huella confiada de un endpoint, permitiendo re-confiar en la
    /// próxima conexión. Lo usa la UI para resolver un `HostKeyMismatchError` tras
    /// una reinstalación legítima del servidor, sin editar el JSON a mano.
    static func forget(host: String, port: Int, storeURL: URL = defaultStoreURL()) {
        let endpoint = "\(host):\(port)"
        fileLock.lock()
        defer { fileLock.unlock() }
        var known = load(from: storeURL)
        guard known.removeValue(forKey: endpoint) != nil else { return }
        save(known, to: storeURL)
        Log.hostKey.notice("Huella olvidada para \(endpoint, privacy: .public); se re-confiará en la próxima conexión.")
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
        )) ?? URL.applicationSupportDirectory

        let directory = base.appendingPathComponent("Argos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("known_hosts.json")
    }

    private static func load(from url: URL) -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Archivo inexistente en el primer uso: caso normal (no es error).
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // El archivo EXISTE pero no parsea => corrupción. Es relevante para
            // seguridad: devolver [:] re-confiaría en todos los hosts (TOFU). Lo
            // dejamos registrado en vez de tragarlo en silencio.
            Log.hostKey.error("known_hosts corrupto en \(url.path, privacy: .public); se ignora y se re-confiará en hosts: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private static func save(_ dictionary: [String: String], to url: URL) {
        do {
            let data = try JSONEncoder().encode(dictionary)
            try data.write(to: url, options: .atomic)
        } catch {
            // Si no se persiste, la huella no se recordará y se re-confiará en el
            // próximo arranque: lo registramos para que el fallo sea observable.
            Log.hostKey.error("No se pudo persistir known_hosts en \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
