//
//  SSHKeyInspectorTests.swift
//  ArgosTests
//
//  Detección del tipo de clave al importar o pegar (antes una RSA se daba por buena y
//  fallaba al conectar), y el par de claves creado en el dispositivo.
//

import Citadel
import Crypto
import Foundation
import Testing
@testable import Argos

@Suite("Inspector de claves SSH")
struct SSHKeyInspectorTests {

    // MARK: - Construcción de claves OpenSSH de prueba

    private static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func string(_ value: Data) -> Data { uint32(UInt32(value.count)) + value }
    private static func string(_ value: String) -> Data { string(Data(value.utf8)) }

    /// Contenedor `openssh-key-v1` con el tipo y el cifrado pedidos (la parte privada
    /// es relleno: el inspector no la descifra).
    private static func openSSH(type: String, cipher: String = "none") -> String {
        var body = Data("openssh-key-v1".utf8) + Data([0])
        body += string(cipher)
        body += string(cipher == "none" ? "none" : "bcrypt")
        body += string(Data())
        body += uint32(1)
        body += string(string(type) + string(Data(repeating: 9, count: 32)))
        body += string(Data(repeating: 1, count: 64))
        let base64 = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "\(SSHKeyInspector.openSSHHeader)\n\(base64)\n\(SSHKeyInspector.openSSHFooter)\n"
    }

    // MARK: - Ed25519

    @Test("Una Ed25519 real se acepta sin passphrase y la normalizada la lee Citadel")
    func realEd25519() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = OpenSSHKeyWriter.privateKeyPEM(key, comment: "prueba")
        guard case .supported(let encrypted, let text) = SSHKeyInspector.inspect(pem) else {
            Issue.record("Debería aceptarse")
            return
        }
        #expect(!encrypted)
        let parsed = try Curve25519.Signing.PrivateKey(sshEd25519: text)
        #expect(parsed.rawRepresentation == key.rawRepresentation)
    }

    @Test("Una Ed25519 pegada en una sola línea o con CRLF se normaliza")
    func pastedOnOneLine() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pem = OpenSSHKeyWriter.privateKeyPEM(key, comment: "c")
        let oneLine = "  " + pem.replacingOccurrences(of: "\n", with: " ") + "  "
        let crlf = pem.replacingOccurrences(of: "\n", with: "\r\n")
        for variant in [oneLine, crlf] {
            guard case .supported(_, let text) = SSHKeyInspector.inspect(variant) else {
                Issue.record("Debería aceptarse: \(variant.prefix(40))")
                continue
            }
            #expect(text.hasPrefix(SSHKeyInspector.openSSHHeader + "\n"))
            #expect(text.hasSuffix(SSHKeyInspector.openSSHFooter + "\n"))
            #expect(try Curve25519.Signing.PrivateKey(sshEd25519: text).rawRepresentation == key.rawRepresentation)
        }
    }

    @Test("Detecta la passphrase de una Ed25519 cifrada")
    func encryptedEd25519() {
        guard case .supported(let encrypted, _) = SSHKeyInspector.inspect(Self.openSSH(type: "ssh-ed25519", cipher: "aes256-ctr")) else {
            Issue.record("Debería aceptarse")
            return
        }
        #expect(encrypted)
    }

    // MARK: - No admitidas

    @Test("RSA, ECDSA, DSA y llave física en formato OpenSSH se rechazan con su tipo",
          arguments: [
            ("ssh-rsa", SSHKeyAlgorithm.rsa),
            ("ecdsa-sha2-nistp256", .ecdsa),
            ("ssh-dss", .dsa),
            ("sk-ssh-ed25519@openssh.com", .securityKey),
            ("ssh-raro", .unknown),
          ])
    func unsupportedOpenSSH(type: String, algorithm: SSHKeyAlgorithm) {
        #expect(SSHKeyInspector.inspect(Self.openSSH(type: type)) == .unsupported(.unsupportedAlgorithm(algorithm)))
        // Con passphrase también se sabe el tipo (la parte pública no va cifrada).
        #expect(SSHKeyInspector.inspect(Self.openSSH(type: type, cipher: "aes256-ctr"))
                == .unsupported(.unsupportedAlgorithm(algorithm)))
    }

    @Test("El formato PEM antiguo se reconoce con su algoritmo")
    func legacyPEM() {
        #expect(SSHKeyInspector.inspect("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nabc\n-----END RSA PRIVATE KEY-----")
                == .unsupported(.legacyPEM(.rsa)))
        #expect(SSHKeyInspector.inspect("-----BEGIN EC PRIVATE KEY-----\nabc\n-----END EC PRIVATE KEY-----")
                == .unsupported(.legacyPEM(.ecdsa)))
        #expect(SSHKeyInspector.inspect("-----BEGIN ENCRYPTED PRIVATE KEY-----\nabc\n-----END ENCRYPTED PRIVATE KEY-----")
                == .unsupported(.legacyPEM(.unknown)))
        // PKCS#8 de `openssl genpkey -algorithm ed25519`.
        let ed25519PKCS8 = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70,
                                 0x04, 0x22, 0x04, 0x20] + Array(repeating: UInt8(7), count: 32))
        let pkcs8 = "-----BEGIN PRIVATE KEY-----\n\(ed25519PKCS8.base64EncodedString())\n-----END PRIVATE KEY-----"
        #expect(SSHKeyInspector.inspect(pkcs8) == .unsupported(.legacyPEM(.ed25519)))
        #expect(SSHKeyProblem.legacyPEM(.ed25519).userMessage().contains("ssh-keygen -p"))
    }

    @Test("Una clave pública pegada por error se distingue")
    func publicKey() {
        let line = OpenSSHKeyWriter.authorizedKeyLine(Curve25519.Signing.PrivateKey().publicKey, comment: "yo@mac")
        #expect(SSHKeyInspector.inspect(line) == .unsupported(.publicKey))
        #expect(SSHKeyInspector.inspect("---- BEGIN SSH2 PUBLIC KEY ----") == .unsupported(.notAKey))
        #expect(SSHKeyInspector.inspect("-----BEGIN SSH2 PUBLIC KEY-----\nAAAA\n-----END SSH2 PUBLIC KEY-----")
                == .unsupported(.publicKey))
    }

    @Test("PuTTY, texto cualquiera, copia incompleta, binario y archivos enormes")
    func otherInputs() {
        #expect(SSHKeyInspector.inspect("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none") == .unsupported(.puttyKey))
        #expect(SSHKeyInspector.inspect("hola, esto no es una clave") == .unsupported(.notAKey))
        #expect(SSHKeyInspector.inspect("") == .unsupported(.notAKey))
        let cut = String(Self.openSSH(type: "ssh-ed25519").prefix(80)) + "\n" + SSHKeyInspector.openSSHFooter
        #expect(SSHKeyInspector.inspect(cut) == .unsupported(.malformed))
        #expect(SSHKeyInspector.inspect(SSHKeyInspector.openSSHHeader) == .unsupported(.notAKey))
        #expect(SSHKeyInspector.inspect(data: Data([0xFF, 0xFE, 0xFD])) == .unsupported(.unreadable))
        #expect(SSHKeyInspector.inspect(data: Data(repeating: 65, count: SSHKeyInspector.maxBytes + 1))
                == .unsupported(.tooLarge))
    }

    @Test("El mensaje recomienda Ed25519 y admite una salida propia de la plataforma")
    func messages() {
        let rsa = SSHKeyProblem.unsupportedAlgorithm(.rsa)
        #expect(rsa.userMessage().contains("RSA"))
        #expect(rsa.userMessage().contains("ssh-keygen -t ed25519"))
        #expect(rsa.userMessage(alternative: "usa «Crear clave en este iPhone»").hasSuffix("usa «Crear clave en este iPhone»."))
        #expect(rsa.errorDescription == rsa.userMessage())
        #expect(SSHKeyProblem.publicKey.userMessage().contains("PRIVADA"))
    }

    // MARK: - Validación estricta y clave del dispositivo

    @Test("validateSupported lanza el problema concreto")
    func strictValidation() throws {
        #expect(throws: SSHKeyProblem.unsupportedAlgorithm(.rsa)) {
            try ImportedKeyStore.validateSupported(Data(Self.openSSH(type: "ssh-rsa").utf8))
        }
        let pem = OpenSSHKeyWriter.privateKeyPEM(Curve25519.Signing.PrivateKey(), comment: "c")
        let result = try ImportedKeyStore.validateSupported(Data(pem.utf8))
        #expect(!result.isEncrypted)
        #expect(result.text == pem)
    }

    @Test("La clave creada en el dispositivo es coherente y se puede volver a leer su pública")
    func deviceKeyPair() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let pair = DeviceKeyPair.generate(date: date)
        #expect(pair.comment.hasPrefix(AuthorizedDeviceKey.commentPrefix))
        #expect(pair.authorizedKeyLine.hasSuffix(" \(pair.comment)"))
        // La línea la reconoce «Dispositivos autorizados» del Mac.
        #expect(AuthorizedDeviceKey.parse(line: pair.authorizedKeyLine)?.comment == pair.comment)
        let parsed = try Curve25519.Signing.PrivateKey(sshEd25519: pair.privateKeyPEM)
        #expect(OpenSSHKeyWriter.authorizedKeyLine(parsed.publicKey, comment: pair.comment) == pair.authorizedKeyLine)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-\(UUID().uuidString)/keys", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let id = UUID()
        try ImportedKeyStore.store(Data(pair.privateKeyPEM.utf8), for: id, in: directory)
        #expect(ImportedKeyStore.publicKeyLine(for: id, comment: pair.comment, in: directory) == pair.authorizedKeyLine)
        #expect(ImportedKeyStore.publicKeyLine(for: UUID(), comment: "x", in: directory) == nil)
    }
}
