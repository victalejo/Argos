//
//  SSHKeyInspector.swift
//  Argos
//
//  Mira qué es un texto o archivo que el usuario quiere usar como clave SSH, ANTES de
//  guardarlo: Argos (Citadel) solo autentica con claves Ed25519 en formato OpenSSH, y
//  hasta ahora una RSA se daba por buena al importarla y fallaba al conectar con un
//  mensaje confuso. Lógica pura (sin red ni UI): distingue Ed25519, RSA, ECDSA, DSA,
//  claves de llave física (`sk-`), el formato PEM antiguo, PuTTY, una clave PÚBLICA
//  pegada por error y texto que no es una clave; y si la clave tiene passphrase.
//
//  Formato OpenSSH (`openssh-key-v1`, ver PROTOCOL.key de OpenSSH):
//      "openssh-key-v1\0" string cifrado, string kdf, string opciones-kdf,
//      uint32 nº-claves, string clave-pública (string tipo, …), string privada
//  La parte pública va SIN cifrar, así que el tipo se lee aunque haya passphrase.
//

import Foundation

/// Algoritmo de una clave SSH.
enum SSHKeyAlgorithm: String, Sendable, Equatable, CaseIterable {
    case ed25519
    case rsa
    case ecdsa
    case dsa
    /// Llave física FIDO (`sk-ssh-ed25519@openssh.com`, `sk-ecdsa-…`).
    case securityKey
    case unknown

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .rsa: return "RSA"
        case .ecdsa: return "ECDSA"
        case .dsa: return "DSA"
        case .securityKey: return "de llave física (FIDO)"
        case .unknown: return "de tipo desconocido"
        }
    }

    /// Tipo de clave tal como aparece en el formato SSH (`ssh-ed25519`, `ssh-rsa`…).
    init(sshKeyType: String) {
        switch sshKeyType {
        case "ssh-ed25519": self = .ed25519
        case "ssh-rsa": self = .rsa
        case "ssh-dss": self = .dsa
        case let type where type.hasPrefix("sk-"): self = .securityKey
        case let type where type.hasPrefix("ecdsa-sha2-"): self = .ecdsa
        default: self = .unknown
        }
    }
}

/// Por qué un texto no sirve como clave para Argos (mensaje accionable).
enum SSHKeyProblem: LocalizedError, Equatable, Sendable {
    /// Clave OpenSSH válida pero de un algoritmo que Argos no admite.
    case unsupportedAlgorithm(SSHKeyAlgorithm)
    /// Formato PEM antiguo (`-----BEGIN RSA PRIVATE KEY-----`, PKCS#8…).
    case legacyPEM(SSHKeyAlgorithm)
    /// Archivo `.ppk` de PuTTY.
    case puttyKey
    /// Se pegó la clave PÚBLICA (`ssh-ed25519 AAAA… usuario@equipo`).
    case publicKey
    /// Cabecera OpenSSH correcta pero contenido dañado (copia incompleta).
    case malformed
    /// No parece una clave SSH.
    case notAKey
    case tooLarge
    case unreadable

    /// Recomendación común: cómo conseguir una clave que sí funciona.
    static let ed25519Hint = "Argos admite claves Ed25519; crea una con «ssh-keygen -t ed25519»"

    /// Mensaje para la interfaz. `alternative` añade otra salida propia de la
    /// plataforma (p. ej. «usa "Crear clave en este iPhone"»).
    func userMessage(alternative: String? = nil) -> String {
        let hint = alternative.map { "\(Self.ed25519Hint) o \($0)." } ?? "\(Self.ed25519Hint)."
        switch self {
        case .unsupportedAlgorithm(let algorithm):
            return "Es una clave \(algorithm.displayName). \(hint)"
        case .legacyPEM(.ed25519):
            return "Es una clave Ed25519 en formato PEM antiguo. Conviértela al formato OpenSSH con «ssh-keygen -p -f <archivo>» y vuelve a importarla."
        case .legacyPEM(let algorithm):
            let what = algorithm == .unknown ? "una clave en formato PEM antiguo" : "una clave \(algorithm.displayName) en formato PEM antiguo"
            return "Es \(what). \(hint)"
        case .puttyKey:
            return "Es una clave de PuTTY (.ppk). Expórtala en formato OpenSSH (PuTTYgen → Conversions → Export OpenSSH key) si es Ed25519. \(hint)"
        case .publicKey:
            return "Es una clave PÚBLICA (la que va en authorized_keys del servidor). Aquí hace falta la PRIVADA (el archivo sin «.pub», que empieza por «-----BEGIN OPENSSH PRIVATE KEY-----»)."
        case .malformed:
            return "La clave parece incompleta o dañada. Cópiala entera, desde «-----BEGIN OPENSSH PRIVATE KEY-----» hasta «-----END OPENSSH PRIVATE KEY-----»."
        case .notAKey:
            return "El texto no es una clave privada SSH. \(hint)"
        case .tooLarge:
            return "El archivo es demasiado grande para ser una clave SSH."
        case .unreadable:
            return "No se pudo leer el archivo de la clave (no es texto)."
        }
    }

    var errorDescription: String? { userMessage() }
}

/// Resultado de inspeccionar una clave.
enum SSHKeyInspection: Equatable, Sendable {
    /// Clave privada Ed25519 OpenSSH que Argos puede usar, ya normalizada (cabecera,
    /// cuerpo en líneas de 70 y pie, con salto final). `isEncrypted`: lleva passphrase.
    case supported(isEncrypted: Bool, normalizedText: String)
    case unsupported(SSHKeyProblem)

    var problem: SSHKeyProblem? {
        if case .unsupported(let problem) = self { return problem }
        return nil
    }
}

enum SSHKeyInspector {
    static let openSSHHeader = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let openSSHFooter = "-----END OPENSSH PRIVATE KEY-----"
    /// Una clave Ed25519 ocupa ~400 bytes; 16 KB deja margen sin aceptar cualquier cosa.
    static let maxBytes = 16 * 1024
    private static let magic = Data("openssh-key-v1".utf8) + Data([0])

    /// Inspecciona el contenido de un archivo.
    static func inspect(data: Data) -> SSHKeyInspection {
        guard data.count <= maxBytes else { return .unsupported(.tooLarge) }
        guard let text = String(data: data, encoding: .utf8) else { return .unsupported(.unreadable) }
        return inspect(text)
    }

    /// Inspecciona un texto (archivo o pegado). Tolera espacios, saltos de línea de
    /// Windows y una clave pegada en una sola línea.
    static func inspect(_ text: String) -> SSHKeyInspection {
        guard text.utf8.count <= maxBytes else { return .unsupported(.tooLarge) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let body = armoredBody(in: trimmed, header: openSSHHeader, footer: openSSHFooter) {
            return inspectOpenSSH(body: body)
        }
        if trimmed.hasPrefix("PuTTY-User-Key-File-") { return .unsupported(.puttyKey) }
        if let legacy = legacyAlgorithm(trimmed) { return .unsupported(.legacyPEM(legacy)) }
        if isPublicKey(trimmed) { return .unsupported(.publicKey) }
        return .unsupported(.notAKey)
    }

    // MARK: - OpenSSH

    private static func inspectOpenSSH(body: String) -> SSHKeyInspection {
        let compact = body.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact), data.starts(with: magic) else {
            return .unsupported(.malformed)
        }
        var reader = SSHWireReader(data: data.dropFirst(magic.count))
        guard let cipher = reader.readString(),
              reader.readString() != nil,             // kdf
              reader.readString() != nil,             // opciones del kdf
              let count = reader.readUInt32(), count >= 1,
              let publicBlob = reader.readData()
        else { return .unsupported(.malformed) }
        var blobReader = SSHWireReader(data: publicBlob)
        guard let type = blobReader.readString() else { return .unsupported(.malformed) }
        let algorithm = SSHKeyAlgorithm(sshKeyType: type)
        guard algorithm == .ed25519 else { return .unsupported(.unsupportedAlgorithm(algorithm)) }
        return .supported(isEncrypted: cipher != "none", normalizedText: normalized(base64: compact))
    }

    /// Texto canónico: cabecera, base64 en líneas de 70 (como `ssh-keygen`) y pie.
    private static func normalized(base64: String) -> String {
        var lines: [Substring] = []
        var rest = Substring(base64)
        while !rest.isEmpty {
            lines.append(rest.prefix(70))
            rest = rest.dropFirst(70)
        }
        return ([openSSHHeader] + lines.map(String.init) + [openSSHFooter]).joined(separator: "\n") + "\n"
    }

    /// Lo que hay entre cabecera y pie, si ambos están (en ese orden).
    private static func armoredBody(in text: String, header: String, footer: String) -> String? {
        guard let start = text.range(of: header),
              let end = text.range(of: footer, range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    // MARK: - Otros formatos

    /// Algoritmo de una clave PEM antigua (`nil` si no lo es).
    private static func legacyAlgorithm(_ text: String) -> SSHKeyAlgorithm? {
        let headers: [(String, SSHKeyAlgorithm?)] = [
            ("-----BEGIN RSA PRIVATE KEY-----", .rsa),
            ("-----BEGIN EC PRIVATE KEY-----", .ecdsa),
            ("-----BEGIN DSA PRIVATE KEY-----", .dsa),
            ("-----BEGIN PRIVATE KEY-----", nil),           // PKCS#8: mirar el OID
            ("-----BEGIN ENCRYPTED PRIVATE KEY-----", .unknown),
        ]
        for (header, algorithm) in headers where text.contains(header) {
            if let algorithm { return algorithm }
            let footer = header.replacingOccurrences(of: "BEGIN", with: "END")
            let body = armoredBody(in: text, header: header, footer: footer)?.filter { !$0.isWhitespace }
            let der = body.flatMap { Data(base64Encoded: $0) } ?? Data()
            return pkcs8Algorithm(der)
        }
        return nil
    }

    /// OID del algoritmo dentro de un PKCS#8 (DER), buscado por sus bytes.
    private static func pkcs8Algorithm(_ der: Data) -> SSHKeyAlgorithm {
        let oids: [([UInt8], SSHKeyAlgorithm)] = [
            ([0x06, 0x03, 0x2B, 0x65, 0x70], .ed25519),                                  // 1.3.101.112
            ([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01], .rsa),  // rsaEncryption
            ([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01], .ecdsa),            // ecPublicKey
        ]
        for (oid, algorithm) in oids where der.range(of: Data(oid)) != nil { return algorithm }
        return .unknown
    }

    /// Línea de clave pública (`authorized_keys`) o bloque SSH2 público.
    private static func isPublicKey(_ text: String) -> Bool {
        if text.contains("-----BEGIN SSH2 PUBLIC KEY-----") { return true }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 2 else { return false }
        let type = String(tokens[0])
        let known = SSHKeyAlgorithm(sshKeyType: type) != .unknown
        return known && Data(base64Encoded: String(tokens[1])) != nil
    }
}

/// Lector del formato binario de SSH (RFC 4251): `uint32` y `string` con longitud.
private struct SSHWireReader {
    private var data: Data

    init<D: DataProtocol>(data: D) {
        self.data = Data(data)
    }

    mutating func readUInt32() -> UInt32? {
        guard data.count >= 4 else { return nil }
        let value = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        data = Data(data.dropFirst(4))
        return value
    }

    mutating func readData() -> Data? {
        guard let length = readUInt32(), length <= UInt32(data.count) else { return nil }
        let value = Data(data.prefix(Int(length)))
        data = Data(data.dropFirst(Int(length)))
        return value
    }

    mutating func readString() -> String? {
        readData().flatMap { String(data: $0, encoding: .utf8) }
    }
}
