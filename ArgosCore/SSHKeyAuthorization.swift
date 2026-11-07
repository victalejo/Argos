//
//  SSHKeyAuthorization.swift
//  Argos
//
//  Añade y retira claves públicas del `~/.ssh/authorized_keys` del servidor. Lo usa
//  «Enviar al iPhone»: el Mac (que ya tiene acceso) autoriza una clave nueva creada
//  solo para el iPhone, y la retira si el usuario cancela. «Dispositivos autorizados»
//  lista esas claves (`AuthorizedDeviceKey`) para revocarlas más tarde.
//

import Crypto
import Foundation

/// Clave de un dispositivo autorizado por Argos en `authorized_keys` (comentario
/// `argos-iphone-…`). Las demás claves del servidor se ignoran: Argos no las gestiona.
struct AuthorizedDeviceKey: Identifiable, Equatable, Sendable {
    static let commentPrefix = "argos-iphone-"

    /// Comentario completo: identifica la línea para revocarla.
    let comment: String
    let keyType: String
    /// Huella `SHA256:…` de la clave pública (como `ssh-keygen -lf`).
    let fingerprint: String
    /// Día en que se autorizó; `nil` en las claves con el formato antiguo (sin fecha).
    let authorizedOn: Date?

    var id: String { comment }

    /// Identificador corto para mostrar (primeros 8 caracteres del uuid).
    var shortID: String {
        let rest = comment.dropFirst(Self.commentPrefix.count)
        let uuid = authorizedOn == nil ? rest : rest.dropFirst(9)   // "AAAAMMDD-"
        return String(uuid.prefix(8))
    }

    /// Fecha del comentario: `AAAAMMDD` en calendario gregoriano y zona local.
    static func dateStamp(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromStamp stamp: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        guard stamp.count == 8, stamp.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(stamp)
        else { return nil }
        let components = DateComponents(year: value / 10_000, month: value / 100 % 100, day: value % 100)
        guard let date = calendar.date(from: components), dateStamp(date, calendar: calendar) == stamp
        else { return nil }   // rechaza días imposibles (p. ej. 20261340)
        return date
    }

    /// Extrae las claves de Argos del contenido de `authorized_keys`. Tolera líneas en
    /// blanco, comentarios `#` y opciones delante del tipo de clave.
    static func parse(authorizedKeys text: String) -> [AuthorizedDeviceKey] {
        text.split(whereSeparator: \.isNewline).compactMap { parse(line: String($0)) }
    }

    static func parse(line: String) -> AuthorizedDeviceKey? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let typeIndex = tokens.firstIndex(where: isKeyType),
              typeIndex + 2 < tokens.count,
              let blob = Data(base64Encoded: tokens[typeIndex + 1])
        else { return nil }
        let comment = tokens[typeIndex + 2]
        guard comment.hasPrefix(commentPrefix) else { return nil }
        return AuthorizedDeviceKey(
            comment: comment,
            keyType: tokens[typeIndex],
            fingerprint: fingerprint(ofBlob: blob),
            authorizedOn: date(fromComment: comment)
        )
    }

    private static func isKeyType(_ token: String) -> Bool {
        token.hasPrefix("ssh-") || token.hasPrefix("ecdsa-") || token.hasPrefix("sk-")
    }

    /// `argos-iphone-AAAAMMDD-<uuid>` → fecha; `argos-iphone-<uuid>` (antiguo) → nil.
    private static func date(fromComment comment: String) -> Date? {
        let rest = comment.dropFirst(commentPrefix.count)
        guard rest.count > 9, rest[rest.index(rest.startIndex, offsetBy: 8)] == "-" else { return nil }
        return date(fromStamp: String(rest.prefix(8)))
    }

    static func fingerprint(ofBlob blob: Data) -> String {
        let base64 = Data(SHA256.hash(data: blob)).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }
}

extension SSHService {
    /// Añade `line` al final de `authorized_keys` (crea `~/.ssh` con permisos 0700 y el
    /// archivo con 0600 si no existen).
    static func authorizeKeyCommand(line: String) -> String {
        "umask 077 && mkdir -p \"$HOME/.ssh\" && "
            + "printf '%s\\n' \(ShellQuoting.singleQuoted(line)) >> \"$HOME/.ssh/authorized_keys\""
    }

    /// Reescribe `authorized_keys` sin las líneas que contienen ` <comment>`. Solo
    /// sobrescribe si `grep` terminó bien (0 = quedan líneas, 1 = no queda ninguna); con
    /// `cat >` el archivo conserva sus permisos y propietario.
    static func revokeKeyCommand(comment: String) -> String {
        "f=\"$HOME/.ssh/authorized_keys\"; [ -f \"$f\" ] || exit 0; "
            + "grep -vF -- \(ShellQuoting.singleQuoted(" " + comment)) \"$f\" > \"$f.argos\"; "
            + "s=$?; if [ $s -le 1 ]; then cat \"$f.argos\" > \"$f\"; fi; rm -f \"$f.argos\"; [ $s -le 1 ]"
    }

    /// Lee `authorized_keys` (vacío si no existe).
    static let readAuthorizedKeysCommand =
        "f=\"$HOME/.ssh/authorized_keys\"; if [ -f \"$f\" ]; then cat \"$f\"; fi"

    /// Claves de dispositivos que Argos autorizó en el servidor.
    func listAuthorizedDeviceKeys() async throws -> [AuthorizedDeviceKey] {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.readAuthorizedKeysCommand)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: detail.isEmpty ? "No se pudo leer ~/.ssh/authorized_keys." : detail
            )
        }
        return AuthorizedDeviceKey.parse(authorizedKeys: result.stdout)
    }

    func authorizeKey(line: String) async throws {
        try await runManagementCommand(Self.authorizeKeyCommand(line: line))
    }

    func revokeKey(comment: String) async throws {
        try await runManagementCommand(Self.revokeKeyCommand(comment: comment))
    }
}
