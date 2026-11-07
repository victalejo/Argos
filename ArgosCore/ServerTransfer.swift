//
//  ServerTransfer.swift
//  Argos
//
//  Contenido del QR con el que el Mac pasa un servidor al iPhone/iPad. Es un enlace
//  `argos://add-server?d=<base64url(JSON)>`: lo lee el escáner de Argos y también la
//  cámara del sistema (que abre la app).
//
//  Lleva la semilla de una clave Ed25519 CREADA SOLO para ese dispositivo (el Mac ya la
//  añadió al `authorized_keys` del servidor), así que la clave del Mac nunca sale de él.
//  Caduca a los `lifetime` segundos, y trae la huella de host key que el Mac ya
//  verificó para que el iPhone no tenga que confiar a ciegas en la primera conexión.
//

import Foundation
import Crypto

struct ServerTransfer: Equatable, Sendable {
    static let currentVersion = 1
    /// Validez del QR desde que se genera.
    static let lifetime: TimeInterval = 5 * 60
    /// Margen por relojes desajustados entre Mac e iPhone.
    static let clockSkew: TimeInterval = 60
    static let scheme = "argos"
    static let action = "add-server"

    var name: String
    var host: String
    var port: Int
    var username: String
    /// Semilla (32 bytes) de la clave Ed25519 dedicada.
    var keySeed: Data
    /// Comentario de la clave en `authorized_keys` (para identificarla y revocarla).
    var keyComment: String
    /// Huella `SHA256:…` de la host key confiada por el Mac, si la conoce.
    var hostKeyFingerprint: String?
    var createdAt: Date

    enum DecodeError: LocalizedError, Equatable {
        case notArgosCode
        case malformed
        case unsupportedVersion
        case expired
        case invalidData

        var errorDescription: String? {
            switch self {
            case .notArgosCode:
                return "Este código QR no es de Argos. En el Mac, abre el menú del servidor y elige «Enviar al iPhone…»."
            case .malformed:
                return "El código QR está incompleto o dañado. Genera otro en el Mac."
            case .unsupportedVersion:
                return "Este código lo generó otra versión de Argos. Actualiza Argos en el Mac y en el iPhone."
            case .expired:
                return "El código QR caducó (dura 5 minutos). En el Mac, pulsa «Mostrar de nuevo»."
            case .invalidData:
                return "El código QR contiene datos de servidor no válidos. Genera otro en el Mac."
            }
        }
    }

    // MARK: - Codificación

    /// Forma compacta para que el QR sea pequeño y fácil de leer.
    private struct Payload: Codable {
        let v: Int
        let n: String
        let h: String
        let p: Int
        let u: String
        let k: String
        let c: String
        let f: String?
        let t: Int
    }

    /// Enlace que se codifica en el QR.
    func urlString() -> String {
        let payload = Payload(
            v: Self.currentVersion, n: name, h: host, p: port, u: username,
            k: Self.base64URLEncode(keySeed), c: keyComment, f: hostKeyFingerprint,
            t: Int(createdAt.timeIntervalSince1970)
        )
        let json = (try? JSONEncoder().encode(payload)) ?? Data()
        return "\(Self.scheme)://\(Self.action)?d=\(Self.base64URLEncode(json))"
    }

    /// Lee y valida un enlace escaneado. `now` se inyecta en tests.
    static func decode(_ text: String, now: Date = Date()) throws -> ServerTransfer {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == action
        else { throw DecodeError.notArgosCode }

        guard let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value,
              let json = base64URLDecode(encoded),
              let payload = try? JSONDecoder().decode(Payload.self, from: json)
        else { throw DecodeError.malformed }

        guard payload.v == currentVersion else { throw DecodeError.unsupportedVersion }

        let createdAt = Date(timeIntervalSince1970: TimeInterval(payload.t))
        let age = now.timeIntervalSince(createdAt)
        guard age <= lifetime, age >= -clockSkew else { throw DecodeError.expired }

        guard let seed = base64URLDecode(payload.k), seed.count == 32 else { throw DecodeError.invalidData }
        let transfer = ServerTransfer(
            name: payload.n.trimmingCharacters(in: .whitespacesAndNewlines),
            host: payload.h.trimmingCharacters(in: .whitespacesAndNewlines),
            port: payload.p,
            username: payload.u.trimmingCharacters(in: .whitespacesAndNewlines),
            keySeed: seed,
            keyComment: payload.c,
            hostKeyFingerprint: payload.f,
            createdAt: createdAt
        )
        guard transfer.isValid else { throw DecodeError.invalidData }
        return transfer
    }

    /// Validación de campos (los datos vienen de fuera: nunca se confía en ellos).
    var isValid: Bool {
        let fields = [name, host, username]
        guard !fields.contains(where: \.isEmpty),
              !fields.contains(where: Self.hasControlCharacters),
              !host.contains(where: \.isWhitespace),
              !username.contains(where: \.isWhitespace),
              !host.hasPrefix("-"), !username.hasPrefix("-"),
              (1...65535).contains(port),
              keySeed.count == 32,
              !keyComment.isEmpty, !keyComment.contains(where: \.isWhitespace)
        else { return false }
        if let hostKeyFingerprint, !hostKeyFingerprint.hasPrefix("SHA256:") { return false }
        return true
    }

    // MARK: - Clave

    /// Clave privada en formato OpenSSH, lista para `ImportedKeyStore`.
    func privateKeyPEM() throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keySeed)
        return OpenSSHKeyWriter.privateKeyPEM(key, comment: keyComment)
    }

    /// Comentario único con el que se identifica la clave en `authorized_keys`.
    static func makeKeyComment(id: UUID = UUID()) -> String {
        "argos-iphone-\(id.uuidString.lowercased())"
    }

    // MARK: - Base64URL

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
