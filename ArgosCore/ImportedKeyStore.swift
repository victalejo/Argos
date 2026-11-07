//
//  ImportedKeyStore.swift
//  Argos
//
//  Claves SSH importadas en iPhone/iPad. iOS no tiene `~/.ssh`: el usuario elige el
//  archivo (Archivos, iCloud, AirDrop…) y Argos guarda una COPIA privada en su
//  contenedor (`Application Support/Argos/keys/<id del servidor>`), con permisos 0600,
//  protección de datos de iOS y FUERA de las copias de seguridad. El `Server` guarda
//  esa ruta, pero se resuelve siempre por el id (el contenedor puede cambiar de ruta
//  al reinstalar o restaurar).
//

import Foundation

enum ImportedKeyStore {

    enum ImportError: LocalizedError, Equatable {
        case notOpenSSHKey
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notOpenSSHKey:
                return "El archivo no es una clave privada OpenSSH (debe empezar por «-----BEGIN OPENSSH PRIVATE KEY-----»). Argos admite claves Ed25519."
            case .tooLarge:
                return "El archivo es demasiado grande para ser una clave SSH."
            case .unreadable:
                return "No se pudo leer el archivo de la clave."
            }
        }
    }

    static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    /// Una clave Ed25519 ocupa ~400 bytes; 16 KB deja margen sin aceptar cualquier cosa.
    static let maxBytes = 16 * 1024

    /// Comprueba que `data` parece una clave privada OpenSSH y la devuelve como texto.
    static func validate(_ data: Data) throws -> String {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.unreadable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(header) else { throw ImportError.notOpenSSHKey }
        return trimmed + "\n"
    }

    /// Guarda la clave del servidor y devuelve su ruta absoluta.
    @discardableResult
    static func store(_ data: Data, for serverID: UUID, in directory: URL = defaultDirectory()) throws -> String {
        let text = try validate(data)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = keyURL(for: serverID, in: directory)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try Data(text.utf8).write(to: url, options: options)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var backupURL = url
        try backupURL.setResourceValues(excluded)
        return url.path
    }

    /// Borra la clave del servidor (idempotente).
    static func remove(for serverID: UUID, in directory: URL = defaultDirectory()) {
        try? FileManager.default.removeItem(at: keyURL(for: serverID, in: directory))
    }

    /// `true` si `path` es la clave importada por Argos para `serverID` (`…/keys/<id>`),
    /// aunque el contenedor haya cambiado de ruta desde que se guardó.
    static func isImported(path: String, for serverID: UUID) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.lastPathComponent == serverID.uuidString
            && url.deletingLastPathComponent().lastPathComponent == "keys"
    }

    /// Ruta efectiva de la clave: si es una importada, la del contenedor ACTUAL.
    static func resolvedPath(_ path: String, for serverID: UUID, in directory: URL = defaultDirectory()) -> String {
        isImported(path: path, for: serverID) ? keyURL(for: serverID, in: directory).path : path
    }

    static func keyURL(for serverID: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(serverID.uuidString, isDirectory: false)
    }

    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.applicationSupportDirectory
        return base.appendingPathComponent("Argos/keys", isDirectory: true)
    }
}
