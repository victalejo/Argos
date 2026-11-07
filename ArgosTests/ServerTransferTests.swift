//
//  ServerTransferTests.swift
//  ArgosTests
//
//  Paso de servidores del Mac al iPhone por QR: serialización OpenSSH de la clave
//  dedicada (verificada con el parser de Citadel, el que usa la conexión real), enlace
//  del QR (ida y vuelta, caducidad, validación) y comandos de authorized_keys.
//

import Foundation
import Testing
import Crypto
import Citadel
@testable import Argos

@Suite("Transferencia de servidores por QR")
struct ServerTransferTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func sample(createdAt: Date = now) -> ServerTransfer {
        ServerTransfer(
            name: "dev", host: "dev.example.com", port: 2222, username: "victor",
            keySeed: Data(repeating: 7, count: 32),
            keyComment: "argos-iphone-abc",
            hostKeyFingerprint: "SHA256:abcdef",
            createdAt: createdAt
        )
    }

    // MARK: - Clave OpenSSH

    @Test("La clave privada generada la lee Citadel y es la misma")
    func privateKeyRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = OpenSSHKeyWriter.privateKeyPEM(key, comment: "argos-iphone-x")
        #expect(pem.hasPrefix(OpenSSHKeyWriter.pemHeader))
        let parsed = try Curve25519.Signing.PrivateKey(sshEd25519: pem)
        #expect(parsed.rawRepresentation == key.rawRepresentation)
        #expect(parsed.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
    }

    @Test("La clave privada pasa la validación de claves importadas del iPhone")
    func privateKeyAcceptedByImportedKeyStore() throws {
        let pem = OpenSSHKeyWriter.privateKeyPEM(Curve25519.Signing.PrivateKey(), comment: "c")
        #expect(throws: Never.self) { try ImportedKeyStore.validate(Data(pem.utf8)) }
    }

    @Test("La línea de authorized_keys tiene tipo, blob y comentario")
    func authorizedKeyLine() throws {
        let key = Curve25519.Signing.PrivateKey()
        let parts = OpenSSHKeyWriter.authorizedKeyLine(key.publicKey, comment: "argos-iphone-x")
            .split(separator: " ").map(String.init)
        #expect(parts.count == 3)
        #expect(parts[0] == "ssh-ed25519")
        #expect(parts[2] == "argos-iphone-x")
        let blob = try #require(Data(base64Encoded: parts[1]))
        // string "ssh-ed25519" (4+11) + string <32 bytes> (4+32)
        #expect(blob.count == 51)
        #expect(blob.suffix(32) == key.publicKey.rawRepresentation)
    }

    // MARK: - Enlace del QR

    @Test("El enlace se lee igual que se escribió")
    func roundTrip() throws {
        let transfer = Self.sample()
        let url = transfer.urlString()
        #expect(url.hasPrefix("argos://add-server?d="))
        #expect(try ServerTransfer.decode(url, now: Self.now) == transfer)
    }

    @Test("La semilla del QR produce la misma clave en el iPhone")
    func pemFromSeed() throws {
        let key = Curve25519.Signing.PrivateKey()
        var transfer = Self.sample()
        transfer.keySeed = key.rawRepresentation
        let parsed = try Curve25519.Signing.PrivateKey(sshEd25519: try transfer.privateKeyPEM())
        #expect(parsed.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
    }

    @Test("Sin huella de host key también es válido")
    func withoutFingerprint() throws {
        var transfer = Self.sample()
        transfer.hostKeyFingerprint = nil
        #expect(try ServerTransfer.decode(transfer.urlString(), now: Self.now) == transfer)
    }

    @Test("Caduca a los 5 minutos")
    func expiry() throws {
        let url = Self.sample().urlString()
        #expect(throws: Never.self) { try ServerTransfer.decode(url, now: Self.now.addingTimeInterval(299)) }
        #expect(throws: ServerTransfer.DecodeError.expired) {
            try ServerTransfer.decode(url, now: Self.now.addingTimeInterval(301))
        }
    }

    @Test("Tolera un reloj del iPhone algo atrasado, pero no demasiado")
    func clockSkew() throws {
        let url = Self.sample().urlString()
        #expect(throws: Never.self) { try ServerTransfer.decode(url, now: Self.now.addingTimeInterval(-30)) }
        #expect(throws: ServerTransfer.DecodeError.expired) {
            try ServerTransfer.decode(url, now: Self.now.addingTimeInterval(-120))
        }
    }

    @Test("Rechaza QR que no son de Argos", arguments: [
        "https://example.com", "argos://otra-cosa?d=x", "hola", "",
    ])
    func notArgos(text: String) {
        #expect(throws: ServerTransfer.DecodeError.notArgosCode) { try ServerTransfer.decode(text, now: Self.now) }
    }

    @Test("Rechaza contenido dañado", arguments: ["argos://add-server", "argos://add-server?d=no-es-base64!", "argos://add-server?d=e30"])
    func malformed(text: String) {
        #expect(throws: ServerTransfer.DecodeError.malformed) { try ServerTransfer.decode(text, now: Self.now) }
    }

    @Test("Rechaza datos de servidor no válidos")
    func invalidFields() {
        let mutations: [(inout ServerTransfer) -> Void] = [
            { $0.host = "" },
            { $0.host = "a b" },
            { $0.host = "-oProxyCommand=x" },
            { $0.username = "x\ny" },
            { $0.port = 0 },
            { $0.port = 70000 },
            { $0.keySeed = Data(count: 16) },
            { $0.keyComment = "dos palabras" },
            { $0.hostKeyFingerprint = "MD5:aa" },
        ]
        for mutate in mutations {
            var transfer = Self.sample()
            mutate(&transfer)
            #expect(throws: ServerTransfer.DecodeError.invalidData) {
                try ServerTransfer.decode(transfer.urlString(), now: Self.now)
            }
        }
    }

    @Test("Comentario de clave único y sin espacios")
    func keyComment() {
        let comment = ServerTransfer.makeKeyComment()
        #expect(comment.hasPrefix("argos-iphone-"))
        #expect(!comment.contains(" "))
        #expect(comment != ServerTransfer.makeKeyComment())
    }

    // MARK: - authorized_keys

    @Test("Autorizar añade la línea entrecomillada a authorized_keys")
    func authorizeCommand() {
        #expect(
            SSHService.authorizeKeyCommand(line: "ssh-ed25519 AAAA argos-iphone-x")
                == "umask 077 && mkdir -p \"$HOME/.ssh\" && printf '%s\\n' 'ssh-ed25519 AAAA argos-iphone-x' >> \"$HOME/.ssh/authorized_keys\""
        )
    }

    @Test("Revocar filtra por el comentario y solo sobrescribe si grep fue bien")
    func revokeCommand() {
        let command = SSHService.revokeKeyCommand(comment: "argos-iphone-x")
        #expect(command.contains("grep -vF -- ' argos-iphone-x'"))
        #expect(command.contains("if [ $s -le 1 ]; then cat"))
    }
}

@Suite("Huellas de host key recibidas por QR", .serialized)
struct HostKeyTrustTests {
    private static func tempStore() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("argos-known-\(UUID().uuidString).json")
    }

    @Test("Fija la huella si el endpoint es desconocido")
    func trustUnknown() {
        let url = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TOFUHostKeyValidator.trustedFingerprint(host: "h", port: 22, storeURL: url) == nil)
        #expect(TOFUHostKeyValidator.trustIfUnknown(fingerprint: "SHA256:a", host: "h", port: 22, storeURL: url))
        #expect(TOFUHostKeyValidator.trustedFingerprint(host: "h", port: 22, storeURL: url) == "SHA256:a")
        #expect(TOFUHostKeyValidator.trustIfUnknown(fingerprint: "SHA256:a", host: "h", port: 22, storeURL: url))
    }

    @Test("Nunca sustituye una huella distinta ya confiada (anti-MitM)")
    func neverOverwrites() {
        let url = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        TOFUHostKeyValidator.trustIfUnknown(fingerprint: "SHA256:real", host: "h", port: 22, storeURL: url)
        #expect(!TOFUHostKeyValidator.trustIfUnknown(fingerprint: "SHA256:falsa", host: "h", port: 22, storeURL: url))
        #expect(TOFUHostKeyValidator.trustedFingerprint(host: "h", port: 22, storeURL: url) == "SHA256:real")
    }

    @Test("Un QR con otra huella para un servidor conocido se marca como conflicto")
    func transferConflict() {
        let url = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        var transfer = ServerTransfer(
            name: "dev", host: "h", port: 22, username: "u", keySeed: Data(count: 32),
            keyComment: "argos-iphone-x", hostKeyFingerprint: "SHA256:falsa", createdAt: Date()
        )
        #expect(!transfer.conflictsWithTrustedHostKey(storeURL: url))   // desconocido
        TOFUHostKeyValidator.trustIfUnknown(fingerprint: "SHA256:real", host: "h", port: 22, storeURL: url)
        #expect(transfer.conflictsWithTrustedHostKey(storeURL: url))
        transfer.hostKeyFingerprint = "SHA256:real"
        #expect(!transfer.conflictsWithTrustedHostKey(storeURL: url))
        transfer.hostKeyFingerprint = nil
        #expect(!transfer.conflictsWithTrustedHostKey(storeURL: url))
    }
}
