//
//  OpenSSHKeyWriter.swift
//  Argos
//
//  Serializa claves Ed25519 a los formatos de OpenSSH: la clave privada
//  (`-----BEGIN OPENSSH PRIVATE KEY-----`, formato `openssh-key-v1` sin cifrar) y la
//  línea pública de `authorized_keys`. Citadel solo sabe LEER estos formatos; Argos
//  necesita escribirlos para crear la clave dedicada que se pasa al iPhone por QR.
//

import Foundation
import Crypto

enum OpenSSHKeyWriter {
    static let keyType = "ssh-ed25519"
    static let pemHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let pemFooter = "-----END OPENSSH PRIVATE KEY-----"

    /// Blob público SSH: `string "ssh-ed25519"` + `string <32 bytes>`.
    static func publicKeyBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        var blob = Data()
        appendString(Data(keyType.utf8), to: &blob)
        appendString(key.rawRepresentation, to: &blob)
        return blob
    }

    /// Línea de `authorized_keys`: `ssh-ed25519 <base64> <comentario>`.
    static func authorizedKeyLine(_ key: Curve25519.Signing.PublicKey, comment: String) -> String {
        "\(keyType) \(publicKeyBlob(key).base64EncodedString()) \(comment)"
    }

    /// Clave privada en formato OpenSSH sin cifrar. `checkInt` solo se fija en tests
    /// (OpenSSH usa un aleatorio para detectar una passphrase incorrecta).
    static func privateKeyPEM(
        _ key: Curve25519.Signing.PrivateKey,
        comment: String,
        checkInt: UInt32 = .random(in: .min ... .max)
    ) -> String {
        let publicRaw = key.publicKey.rawRepresentation

        var privateSection = Data()
        appendUInt32(checkInt, to: &privateSection)
        appendUInt32(checkInt, to: &privateSection)
        appendString(Data(keyType.utf8), to: &privateSection)
        appendString(publicRaw, to: &privateSection)
        // OpenSSH guarda los 64 bytes "semilla + pública".
        appendString(key.rawRepresentation + publicRaw, to: &privateSection)
        appendString(Data(comment.utf8), to: &privateSection)
        var padding: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(padding)
            padding += 1
        }

        var body = Data("openssh-key-v1".utf8)
        body.append(0)
        appendString(Data("none".utf8), to: &body)   // cifrado
        appendString(Data("none".utf8), to: &body)   // KDF
        appendString(Data(), to: &body)              // opciones del KDF
        appendUInt32(1, to: &body)                   // nº de claves
        appendString(publicKeyBlob(key.publicKey), to: &body)
        appendString(privateSection, to: &body)

        let base64 = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "\(pemHeader)\n\(base64)\n\(pemFooter)\n"
    }

    // MARK: - Codificación SSH (RFC 4251)

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: Data, to data: inout Data) {
        appendUInt32(UInt32(value.count), to: &data)
        data.append(value)
    }
}
