import Foundation
import Testing
@testable import Argos

@Suite("ImportedKeyStore")
struct ImportedKeyStoreTests {
    private let sampleKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    -----END OPENSSH PRIVATE KEY-----
    """

    /// Imita la ruta real (`…/Argos/keys`) dentro de un directorio temporal único.
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-\(UUID().uuidString)/keys", isDirectory: true)
    }

    @Test func aceptaClaveOpenSSHYNormalizaFinal() throws {
        let text = try ImportedKeyStore.validate(Data(("\n  " + sampleKey + "\n\n").utf8))
        #expect(text.hasPrefix(ImportedKeyStore.header))
        #expect(text.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
    }

    @Test func rechazaArchivosQueNoSonClave() {
        #expect(throws: ImportedKeyStore.ImportError.notOpenSSHKey) {
            try ImportedKeyStore.validate(Data("ssh-ed25519 AAAA… usuario@mac".utf8))
        }
        #expect(throws: ImportedKeyStore.ImportError.notOpenSSHKey) {
            try ImportedKeyStore.validate(Data("-----BEGIN RSA PRIVATE KEY-----\nabc".utf8))
        }
    }

    @Test func rechazaArchivosEnormesYBinarios() {
        #expect(throws: ImportedKeyStore.ImportError.tooLarge) {
            try ImportedKeyStore.validate(Data(repeating: 65, count: ImportedKeyStore.maxBytes + 1))
        }
        #expect(throws: ImportedKeyStore.ImportError.unreadable) {
            try ImportedKeyStore.validate(Data([0xFF, 0xFE, 0xFD]))
        }
    }

    @Test func guardaConPermisos0600YBorra() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let id = UUID()

        let path = try ImportedKeyStore.store(Data(sampleKey.utf8), for: id, in: directory)

        #expect(path == ImportedKeyStore.keyURL(for: id, in: directory).path)
        #expect(try String(contentsOfFile: path, encoding: .utf8).hasPrefix(ImportedKeyStore.header))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(ImportedKeyStore.isImported(path: path, for: id))
        let excluded = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(excluded.isExcludedFromBackup == true)

        ImportedKeyStore.remove(for: id, in: directory)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func noConsideraImportadasLasRutasDeFuera() {
        let id = UUID()
        #expect(!ImportedKeyStore.isImported(path: "/Users/alguien/.ssh/id_ed25519", for: id))
        #expect(!ImportedKeyStore.isImported(path: "/tmp/keys/\(UUID())", for: id))
        #expect(!ImportedKeyStore.isImported(path: "/tmp/otra/\(id)", for: id))
    }

    @Test func resuelveLaClaveEnElContenedorActual() {
        let id = UUID()
        let viejo = "/var/mobile/Containers/Data/Application/VIEJO/Library/Application Support/Argos/keys/\(id)"
        let actual = URL(fileURLWithPath: "/contenedor/nuevo/Argos/keys", isDirectory: true)
        #expect(ImportedKeyStore.resolvedPath(viejo, for: id, in: actual) == "/contenedor/nuevo/Argos/keys/\(id)")
        #expect(ImportedKeyStore.resolvedPath("~/.ssh/id_ed25519", for: id, in: actual) == "~/.ssh/id_ed25519")
    }

    @Test func noGuardaUnArchivoInvalido() {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ImportedKeyStore.ImportError.notOpenSSHKey) {
            try ImportedKeyStore.store(Data("hola".utf8), for: UUID(), in: directory)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func pideImportarSiLaClaveVieneDelMacONoExiste() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let id = UUID()
        let delMac = Server(id: id, name: "dev", host: "h", username: "u", authMethod: .key, privateKeyPath: "~/.ssh/dev")
        #expect(ImportedKeyStore.needsImport(delMac, in: directory))

        var importada = delMac
        importada.privateKeyPath = ImportedKeyStore.keyURL(for: id, in: directory).path
        #expect(ImportedKeyStore.needsImport(importada, in: directory)) // ruta correcta, archivo ausente
        try ImportedKeyStore.store(Data(sampleKey.utf8), for: id, in: directory)
        #expect(!ImportedKeyStore.needsImport(importada, in: directory))

        let conContrasena = Server(id: id, name: "dev", host: "h", username: "u", authMethod: .password, privateKeyPath: "")
        #expect(!ImportedKeyStore.needsImport(conContrasena, in: directory))
    }
}
